//! Synthetic peers only. Exercises actual TCP/WS framing and generated codecs.
use async_trait::async_trait;
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use futures_util::{SinkExt, StreamExt};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::{net::TcpListener, task::JoinHandle};
use tokio_tungstenite::{accept_async, tungstenite::Message};
use voiceremote_core::{
    Result, TextInjector,
    pairing::{self, Clock, Offer, PendingPair, SystemClock},
    protocol::*,
    session::{Delivery, Session},
    storage::{FileKeyStore, Identity, KeyStore, Registry},
    transport::{LanListener, LanTransport, RelayRoute, RelayTransport, Transport},
};
use zeroize::Zeroizing;

#[derive(Default)]
struct MemoryStore(Mutex<HashMap<String, Vec<u8>>>);
impl KeyStore for MemoryStore {
    fn get(&self, key: &str) -> Result<Option<Zeroizing<Vec<u8>>>> {
        Ok(self.0.lock().unwrap().get(key).cloned().map(Zeroizing::new))
    }
    fn put(&self, key: &str, value: &[u8]) -> Result<()> {
        self.0.lock().unwrap().insert(key.into(), value.to_vec());
        Ok(())
    }
    fn reserve(&self, key: &str) -> Result<bool> {
        let mut data = self.0.lock().unwrap();
        if data.contains_key(key) {
            return Ok(false);
        }
        data.insert(key.into(), b"reserved".to_vec());
        Ok(true)
    }
    fn delete(&self, key: &str) -> Result<()> {
        self.0.lock().unwrap().remove(key);
        Ok(())
    }
}
fn registry() -> Registry {
    Registry::new(Arc::new(MemoryStore::default()))
}
fn info(device: &str) -> DeviceInfo {
    DeviceInfo {
        kind: DeviceInfoKind::DeviceInfo,
        account_id: "synthetic-account".into(),
        device_id: device.into(),
        display_name: "Synthetic peer".into(),
        platform: DeviceInfoPlatform::Linux,
        role: DeviceInfoRole::TextReceiver,
        capabilities: vec![Capability::ReceiveText],
    }
}
fn dictation(text: &str) -> InnerMessage {
    InnerMessage::DictationText(DictationText {
        preparation_id: None,
        kind: DictationTextKind::DictationText,
        account_id: "synthetic-account".into(),
        segment_id: "synthetic-segment".into(),
        revision: 1,
        state: DictationTextState::Committed,
        target_device_id: "desktop".into(),
        text: text.into(),
    })
}
#[derive(Default)]
struct Injector(Vec<String>);
impl TextInjector for Injector {
    fn insert_text(&mut self, text: &str) -> Result<()> {
        self.0.push(text.into());
        Ok(())
    }
}

async fn lan() -> Result<(Box<dyn Transport>, Box<dyn Transport>)> {
    let listener = LanListener::bind("127.0.0.1:0".parse()?).await?;
    let (phone, desktop) = tokio::join!(
        LanTransport::connect(listener.address()?),
        listener.accept()
    );
    Ok((Box::new(phone?), Box::new(desktop?)))
}
/// In-process fake relays only allowlisted metadata/opaque ciphertext. The task
/// performs no Noise parsing and holds no identity, token or plaintext.
async fn relay() -> Result<(Box<dyn Transport>, Box<dyn Transport>, JoinHandle<()>)> {
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let endpoint = format!("ws://{}", listener.local_addr()?);
    let worker = tokio::spawn(async move {
        let first = listener.accept().await.unwrap().0;
        let mut first = accept_async(first).await.unwrap();
        let second = listener.accept().await.unwrap().0;
        let mut second = accept_async(second).await.unwrap();
        loop {
            tokio::select! {
                frame = first.next() => {
                    let Some(Ok(Message::Text(text))) = frame else { break; };
                    assert!(text.len()<=16_384,"fake enforces worker frame cap");
                    let decoded: RelayFrame = decode(&text).unwrap();
                    assert!(!text.contains("one_use_token") && !text.contains("dictation_text"));
                    if let RelayFrame::RelayCiphertext(_) = decoded { if second.send(Message::Text(text)).await.is_err() { break; } }
                },
                frame = second.next() => {
                    let Some(Ok(Message::Text(text))) = frame else { break; };
                    assert!(text.len()<=16_384,"fake enforces worker frame cap");
                    let decoded: RelayFrame = decode(&text).unwrap();
                    assert!(!text.contains("one_use_token") && !text.contains("dictation_text"));
                    if let RelayFrame::RelayCiphertext(_) = decoded { if first.send(Message::Text(text)).await.is_err() { break; } }
                }
            }
        }
    });
    let route = |sender: &str| RelayRoute {
        account: "synthetic-account".into(),
        room: "synthetic-room".into(),
        sender: sender.into(),
    };
    let phone = RelayTransport::connect_loopback(&endpoint, route("phone")).await?;
    let desktop = RelayTransport::connect_loopback(&endpoint, route("desktop")).await?;
    Ok((Box::new(phone), Box::new(desktop), worker))
}
async fn pending(
    phone: &mut dyn Transport,
    desktop: &mut dyn Transport,
    pi: &Identity,
    di: &Identity,
    offer: &mut Offer,
) -> Result<(PendingPair, PendingPair)> {
    let payload = offer.payload.clone();
    let (p, d) = tokio::join!(
        pairing::initiate(phone, pi, &payload, &SystemClock),
        pairing::accept(desktop, di, offer, &SystemClock)
    );
    Ok((p?, d?))
}
async fn enroll(
    phone: &mut dyn Transport,
    desktop: &mut dyn Transport,
    pr: Registry,
    dr: Registry,
) -> Result<(Session, Session, Identity, Identity, Offer)> {
    let pi = Identity::generate()?;
    let di = Identity::generate()?;
    let mut offer = Offer::issue(
        &di,
        "synthetic-account".into(),
        "synthetic-room".into(),
        &SystemClock,
    )?;
    // QR round-trip uses the generated, strict contract codec.
    let encoded = encode(&offer.payload).map_err(anyhow::Error::msg)?;
    assert_eq!(
        decode::<PairingPayload>(&encoded).map_err(anyhow::Error::msg)?,
        offer.payload
    );
    let (mut p, mut d) = pending(phone, desktop, &pi, &di, &mut offer).await?;
    assert_eq!(p.phrase(), d.phrase());
    assert_eq!(p.phrase().split(' ').count(), 4);
    let phrase = p.phrase();
    p.confirm_local(phone, &phrase, info("phone")).await?;
    d.confirm_local(desktop, &phrase, info("desktop")).await?;
    let (a, b) = tokio::join!(
        p.receive_confirmation(phone),
        d.receive_confirmation(desktop)
    );
    a?;
    b?;
    Ok((p.finish(pr)?, d.finish(dr)?, pi, di, offer))
}

#[tokio::test]
async fn full_xx_lan_qr_pair_under_one_minute_and_literal_delivery() -> Result<()> {
    let start = Instant::now();
    let (mut p, mut d) = lan().await?;
    let (mut ps, mut ds, ..) = enroll(p.as_mut(), d.as_mut(), registry(), registry()).await?;
    ps.send(p.as_mut(), &dictation("Synthetic sample")).await?;
    let message = ds.receive(d.as_mut()).await?;
    let mut injector = Injector::default();
    assert_eq!(
        ds.deliver(d.as_mut(), message, &mut injector).await?,
        Delivery::Inserted
    );
    assert_eq!(injector.0, ["Synthetic sample"]);
    assert!(matches!(
        ps.receive(p.as_mut()).await?,
        InnerMessage::DictationOutcome(DictationOutcome {
            outcome: DictationOutcomeOutcome::Inserted,
            ..
        })
    ));
    ds.deliver(
        d.as_mut(),
        InnerMessage::DictationQuery(DictationQuery {
            kind: DictationQueryKind::DictationQuery,
            account_id: "synthetic-account".into(),
            segment_id: "synthetic-segment".into(),
            target_device_id: "desktop".into(),
        }),
        &mut injector,
    )
    .await?;
    assert!(matches!(
        ps.receive(p.as_mut()).await?,
        InnerMessage::DictationOutcome(DictationOutcome {
            outcome: DictationOutcomeOutcome::Inserted,
            ..
        })
    ));
    assert_eq!(injector.0.len(), 1);
    assert!(start.elapsed() < Duration::from_secs(60));
    eprintln!(
        "synthetic LAN QR pair + delivery compute: {:?}; human time unverified",
        start.elapsed()
    );
    Ok(())
}

#[tokio::test]
async fn pre_input_failure_reports_to_phone_and_same_segment_can_retry_without_reconnect()
-> Result<()> {
    struct BlockedOnce(bool);
    impl TextInjector for BlockedOnce {
        fn insert_text(&mut self, _: &str) -> Result<()> {
            if !self.0 {
                self.0 = true;
                return Err(voiceremote_core::InsertionFailure::NotStarted.into());
            }
            Ok(())
        }
    }
    let (mut p, mut d) = lan().await?;
    let (mut ps, mut ds, ..) = enroll(p.as_mut(), d.as_mut(), registry(), registry()).await?;
    let mut injector = BlockedOnce(false);
    let text = dictation("Synthetic retry");
    assert_eq!(
        ds.deliver(d.as_mut(), text.clone(), &mut injector).await?,
        Delivery::InsertionNotStarted
    );
    let InnerMessage::DictationOutcome(status) = ps.receive(p.as_mut()).await? else {
        panic!("missing failure status")
    };
    assert_eq!(status.segment_id, "synthetic-segment");
    assert_eq!(status.outcome, DictationOutcomeOutcome::Unavailable);
    assert_eq!(
        ds.deliver(d.as_mut(), text.clone(), &mut injector).await?,
        Delivery::Inserted
    );
    assert_eq!(
        ds.deliver(d.as_mut(), text, &mut injector).await?,
        Delivery::Duplicate
    );
    Ok(())
}

#[tokio::test]
async fn unknown_or_partial_insertion_reports_uncertainty_and_deduplicates_after_reconnect()
-> Result<()> {
    struct Uncertain(usize);
    impl TextInjector for Uncertain {
        fn insert_text(&mut self, _: &str) -> Result<()> {
            self.0 += 1;
            anyhow::bail!("synthetic unknown delivery")
        }
    }
    let (pr, dr) = (registry(), registry());
    let (mut p, mut d) = lan().await?;
    let (mut ps, mut ds, pi, di, ..) =
        enroll(p.as_mut(), d.as_mut(), pr.clone(), dr.clone()).await?;
    let mut injector = Uncertain(0);
    let text = dictation("Synthetic uncertain");
    assert_eq!(
        ds.deliver(d.as_mut(), text.clone(), &mut injector).await?,
        Delivery::InsertionUnconfirmed
    );
    let InnerMessage::DictationOutcome(status) = ps.receive(p.as_mut()).await? else {
        panic!("missing uncertainty status")
    };
    assert_eq!(status.outcome, DictationOutcomeOutcome::Unconfirmed);
    let (mut p, mut d) = lan().await?;
    let pp = pr.devices()?.remove(0);
    let dp = dr.devices()?.remove(0);
    let (ps, ds) = tokio::join!(
        pairing::resume_initiate(p.as_mut(), &pi, &pr, &pp, "phone"),
        pairing::resume_accept(d.as_mut(), &di, &dr, &dp, "desktop")
    );
    let (mut ps, mut ds) = (ps?, ds?);
    assert_eq!(
        ds.deliver(d.as_mut(), text, &mut injector).await?,
        Delivery::Duplicate
    );
    let InnerMessage::DictationOutcome(status) = ps.receive(p.as_mut()).await? else {
        panic!("missing duplicate uncertainty status")
    };
    assert_eq!(status.outcome, DictationOutcomeOutcome::Unconfirmed);
    assert_eq!(injector.0, 1);
    Ok(())
}
#[tokio::test]
async fn full_xx_relay_qr_pair_under_one_minute() -> Result<()> {
    let start = Instant::now();
    let (mut p, mut d, worker) = relay().await?;
    let dr = registry();
    let (mut ps, mut ds, ..) = enroll(p.as_mut(), d.as_mut(), registry(), dr.clone()).await?;
    ps.send(p.as_mut(), &dictation("Synthetic sample")).await?;
    assert!(matches!(
        ds.receive(d.as_mut()).await?,
        InnerMessage::DictationText(_)
    ));
    dr.revoke(&ds.peer().id)?;
    ps.send(p.as_mut(), &dictation("Synthetic sample")).await?;
    assert!(ds.receive(d.as_mut()).await.is_err());
    assert!(start.elapsed() < Duration::from_secs(60));
    eprintln!(
        "synthetic relay QR pair + delivery compute: {:?}; human time unverified",
        start.elapsed()
    );
    worker.abort();
    Ok(())
}
#[tokio::test]
async fn same_noise_session_can_move_between_lan_and_relay() -> Result<()> {
    let (mut p, mut d) = lan().await?;
    let (mut ps, mut ds, ..) = enroll(p.as_mut(), d.as_mut(), registry(), registry()).await?;
    let (mut rp, mut rd, worker) = relay().await?;
    ps.send(rp.as_mut(), &dictation("Synthetic sample")).await?;
    ds.receive(rd.as_mut()).await?;
    ps.send(p.as_mut(), &dictation("Synthetic sample")).await?;
    ds.receive(d.as_mut()).await?;
    worker.abort();
    Ok(())
}
#[tokio::test]
async fn wrong_confirmation_never_enrolls_and_consumes_token() -> Result<()> {
    let (mut p, mut d) = lan().await?;
    let pi = Identity::generate()?;
    let di = Identity::generate()?;
    let mut offer = Offer::issue(
        &di,
        "synthetic-account".into(),
        "synthetic-room".into(),
        &SystemClock,
    )?;
    let (mut pp, dp) = pending(p.as_mut(), d.as_mut(), &pi, &di, &mut offer).await?;
    assert!(
        pp.confirm_local(p.as_mut(), "wrong phrase", info("phone"))
            .await
            .is_err()
    );
    let reg = registry();
    assert!(pp.finish(reg.clone()).is_err());
    assert!(dp.finish(reg.clone()).is_err());
    assert!(reg.devices()?.is_empty());
    let (_live_peer, mut next) = lan().await?;
    let result = tokio::time::timeout(
        Duration::from_millis(100),
        pairing::accept(next.as_mut(), &di, &mut offer, &SystemClock),
    )
    .await?;
    assert_eq!(
        result.err().expect("used token accepted").to_string(),
        "enrollment token already used"
    );
    Ok(())
}
#[tokio::test]
async fn both_local_and_remote_confirmations_are_mandatory() -> Result<()> {
    let (mut p, mut d) = lan().await?;
    let pi = Identity::generate()?;
    let di = Identity::generate()?;
    let mut offer = Offer::issue(
        &di,
        "synthetic-account".into(),
        "synthetic-room".into(),
        &SystemClock,
    )?;
    let (mut pp, mut dp) = pending(p.as_mut(), d.as_mut(), &pi, &di, &mut offer).await?;
    let phrase = pp.phrase();
    pp.confirm_local(p.as_mut(), &phrase, info("phone")).await?;
    dp.receive_confirmation(d.as_mut()).await?;
    assert!(pp.finish(registry()).is_err());
    assert!(dp.finish(registry()).is_err());
    Ok(())
}
#[tokio::test]
async fn wrong_token_fails_full_handshake() -> Result<()> {
    let (mut p, mut d) = lan().await?;
    let pi = Identity::generate()?;
    let di = Identity::generate()?;
    let mut offer = Offer::issue(
        &di,
        "synthetic-account".into(),
        "synthetic-room".into(),
        &SystemClock,
    )?;
    let mut wrong = offer.payload.clone();
    wrong.one_use_token = B64.encode([0xff; 32]);
    let (p, d) = tokio::join!(
        pairing::initiate(p.as_mut(), &pi, &wrong, &SystemClock),
        pairing::accept(d.as_mut(), &di, &mut offer, &SystemClock)
    );
    assert!(p.is_ok());
    assert!(d.is_err());
    Ok(())
}
struct FixedClock(Option<u64>);
impl Clock for FixedClock {
    fn now_ms(&self) -> Result<u64> {
        self.0
            .ok_or_else(|| anyhow::anyhow!("trusted time unavailable"))
    }
}
#[test]
fn expired_far_future_and_unavailable_time_fail() -> Result<()> {
    let di = Identity::generate()?;
    let offer = Offer::issue(
        &di,
        "synthetic-account".into(),
        "synthetic-room".into(),
        &FixedClock(Some(1000)),
    )?;
    assert_eq!(offer.payload.expires_at, 121000);
    assert!(pairing::validate_offer(&offer.payload, &FixedClock(Some(121000))).is_err());
    assert!(pairing::validate_offer(&offer.payload, &FixedClock(Some(0))).is_err());
    assert!(pairing::validate_offer(&offer.payload, &FixedClock(None)).is_err());
    assert!(
        Offer::issue(
            &di,
            "synthetic-account".into(),
            "synthetic-room".into(),
            &FixedClock(None)
        )
        .is_err()
    );
    Ok(())
}
#[tokio::test]
async fn expired_token_rejected_before_handshake() -> Result<()> {
    let (_live_peer, mut desktop) = lan().await?;
    let di = Identity::generate()?;
    let mut offer = Offer::issue(
        &di,
        "synthetic-account".into(),
        "synthetic-room".into(),
        &FixedClock(Some(1)),
    )?;
    let result = tokio::time::timeout(
        Duration::from_millis(100),
        pairing::accept(desktop.as_mut(), &di, &mut offer, &FixedClock(Some(120001))),
    )
    .await?;
    assert_eq!(
        result.err().expect("expired token accepted").to_string(),
        "expired or far-future enrollment"
    );
    Ok(())
}
#[tokio::test]
async fn qr_static_key_is_verified() -> Result<()> {
    let (mut p, mut d) = lan().await?;
    let pi = Identity::generate()?;
    let di = Identity::generate()?;
    let mut offer = Offer::issue(
        &di,
        "synthetic-account".into(),
        "synthetic-room".into(),
        &SystemClock,
    )?;
    // Both sides see the same prologue but the QR key differs from responder key.
    offer.payload.desktop_public_key = B64.encode(Identity::generate()?.public);
    let payload = offer.payload.clone();
    let phone = pairing::initiate(p.as_mut(), &pi, &payload, &SystemClock);
    let desktop = pairing::accept(d.as_mut(), &di, &mut offer, &SystemClock);
    let result = tokio::time::timeout(Duration::from_secs(1), async { tokio::select! { result = phone => result.map(|_| ()), _ = desktop => panic!("desktop cannot finish without message 3") } }).await?;
    assert!(result.is_err());
    Ok(())
}

struct Capture {
    inner: Box<dyn Transport>,
    last: Arc<Mutex<Vec<u8>>>,
    corrupt: bool,
}
#[async_trait]
impl Transport for Capture {
    async fn send(&mut self, packet: &[u8]) -> Result<()> {
        let mut packet = packet.to_vec();
        if self.corrupt {
            let n = packet.len();
            packet[n - 1] ^= 1;
        }
        *self.last.lock().unwrap() = packet.clone();
        self.inner.send(&packet).await
    }
    async fn recv(&mut self) -> Result<Vec<u8>> {
        self.inner.recv().await
    }
    async fn close(&mut self) -> Result<()> {
        self.inner.close().await
    }
}
#[tokio::test]
async fn replayed_ciphertext_rejected() -> Result<()> {
    let (p, mut d) = lan().await?;
    let last = Arc::new(Mutex::new(vec![]));
    let mut p = Capture {
        inner: p,
        last: last.clone(),
        corrupt: false,
    };
    let (mut ps, mut ds, ..) = enroll(&mut p, d.as_mut(), registry(), registry()).await?;
    ps.send(&mut p, &dictation("Synthetic sample")).await?;
    ds.receive(d.as_mut()).await?;
    let captured = last.lock().unwrap().clone();
    p.inner.send(&captured).await?;
    assert!(ds.receive(d.as_mut()).await.is_err());
    assert!(ds.check_active().is_err());
    Ok(())
}
#[tokio::test]
async fn tampered_ciphertext_rejected() -> Result<()> {
    let (p, mut d) = lan().await?;
    let last = Arc::new(Mutex::new(vec![]));
    let mut p = Capture {
        inner: p,
        last: last.clone(),
        corrupt: false,
    };
    let (mut ps, mut ds, ..) = enroll(&mut p, d.as_mut(), registry(), registry()).await?;
    p.corrupt = true;
    ps.send(&mut p, &dictation("Synthetic sample")).await?;
    assert!(ds.receive(d.as_mut()).await.is_err());
    Ok(())
}
#[cfg(unix)]
#[tokio::test]
async fn revoke_fails_next_message_even_from_separate_storage_handle() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let store = Arc::new(FileKeyStore::new(directory.path().join("keys"))?);
    let reg = Registry::new(store);
    let external = Registry::new(Arc::new(FileKeyStore::new(directory.path().join("keys"))?));
    let (mut p, mut d) = lan().await?;
    let (mut ps, mut ds, ..) = enroll(p.as_mut(), d.as_mut(), registry(), reg.clone()).await?;
    external.revoke(&ds.peer().id)?;
    assert!(reg.devices()?.is_empty());
    ps.send(p.as_mut(), &dictation("Synthetic sample")).await?;
    assert!(ds.receive(d.as_mut()).await.is_err());
    Ok(())
}
#[tokio::test]
async fn remote_revoke_closes_session_and_deletes_enrollment() -> Result<()> {
    let (mut p, mut d) = lan().await?;
    let dr = registry();
    let (mut ps, mut ds, ..) = enroll(p.as_mut(), d.as_mut(), registry(), dr.clone()).await?;
    let revoke = InnerMessage::Revoke(Revoke {
        kind: RevokeKind::Revoke,
        account_id: "synthetic-account".into(),
        device_id: "desktop".into(),
        command_id: "synthetic-revoke".into(),
        idempotency_key: "synthetic-revoke".into(),
        revoked_at: 1000,
    });
    ps.send(p.as_mut(), &revoke).await?;
    let message = ds.receive(d.as_mut()).await?;
    assert_eq!(
        ds.deliver(d.as_mut(), message, &mut Injector::default())
            .await?,
        Delivery::Revoked
    );
    assert!(dr.devices()?.is_empty());
    assert!(ds.receive(d.as_mut()).await.is_err());
    Ok(())
}
#[tokio::test]
async fn newline_and_all_controls_never_reach_injector() -> Result<()> {
    let (mut p, mut d) = lan().await?;
    let (mut ps, mut ds, ..) = enroll(p.as_mut(), d.as_mut(), registry(), registry()).await?;
    let mut injector = Injector::default();
    for code in (0..=31).chain(127..=159).chain([0x2028, 0x2029]) {
        let message = dictation(&format!("Synthetic{}sample", char::from_u32(code).unwrap()));
        assert!(ps.send(p.as_mut(), &message).await.is_err());
        assert!(
            ds.deliver(d.as_mut(), message, &mut injector)
                .await
                .is_err()
        );
    }
    assert!(injector.0.is_empty());
    Ok(())
}
#[tokio::test]
async fn partials_and_repeated_commits_never_duplicate_insertion() -> Result<()> {
    let (mut p, mut d) = lan().await?;
    let (_, mut ds, ..) = enroll(p.as_mut(), d.as_mut(), registry(), registry()).await?;
    let mut injector = Injector::default();
    let mut partial = dictation("Synthetic sample");
    if let InnerMessage::DictationText(text) = &mut partial {
        text.state = DictationTextState::Partial;
        text.revision = 0;
    }
    assert_eq!(
        ds.deliver(d.as_mut(), partial, &mut injector).await?,
        Delivery::Ignored
    );
    assert_eq!(
        ds.deliver(d.as_mut(), dictation("Synthetic sample"), &mut injector)
            .await?,
        Delivery::Inserted
    );
    assert_eq!(
        ds.deliver(d.as_mut(), dictation("Synthetic sample"), &mut injector)
            .await?,
        Delivery::Duplicate
    );
    assert_eq!(injector.0.len(), 1);
    Ok(())
}
#[tokio::test]
async fn reconnect_authenticates_known_keys_and_keeps_idempotency() -> Result<()> {
    let (mut p, mut d) = lan().await?;
    let pr = registry();
    let dr = registry();
    let (ps, ds, pi, di, _) = enroll(p.as_mut(), d.as_mut(), pr.clone(), dr.clone()).await?;
    let pp = ps.peer().clone();
    let dp = ds.peer().clone();
    assert!(dr.claim_command(&dp, "synthetic-command")?);
    let (mut p, mut d) = lan().await?;
    let (ps, ds) = tokio::join!(
        pairing::resume_initiate(p.as_mut(), &pi, &pr, &pp, "phone"),
        pairing::resume_accept(d.as_mut(), &di, &dr, &dp, "desktop")
    );
    let mut ps = ps?;
    let mut ds = ds?;
    assert!(!dr.claim_command(ds.peer(), "synthetic-command")?);
    ps.send(p.as_mut(), &dictation("Synthetic sample")).await?;
    ds.receive(d.as_mut()).await?;
    dr.revoke(&dp.id)?;
    assert!(ds.check_active().is_err());
    assert!(
        pairing::resume_accept(d.as_mut(), &di, &dr, &dp, "desktop")
            .await
            .is_err()
    );
    Ok(())
}
#[tokio::test]
async fn re_enrollment_does_not_revive_old_session() -> Result<()> {
    let (mut p, mut d) = lan().await?;
    let dr = registry();
    let (_, ds, ..) = enroll(p.as_mut(), d.as_mut(), registry(), dr.clone()).await?;
    let peer = ds.peer().clone();
    dr.revoke(&peer.id)?;
    dr.enroll(peer.public_key, peer.room, peer.info)?;
    assert!(ds.check_active().is_err());
    Ok(())
}
#[tokio::test]
async fn cross_account_and_wrong_target_rejected() -> Result<()> {
    let (mut p, mut d) = lan().await?;
    let (_, mut ds, ..) = enroll(p.as_mut(), d.as_mut(), registry(), registry()).await?;
    let mut wrong = dictation("Synthetic sample");
    if let InnerMessage::DictationText(text) = &mut wrong {
        text.account_id = "other-account".into();
    }
    let mut injector = Injector::default();
    assert!(ds.deliver(d.as_mut(), wrong, &mut injector).await.is_err());
    let mut wrong = dictation("Synthetic sample");
    if let InnerMessage::DictationText(text) = &mut wrong {
        text.target_device_id = "other-device".into();
    }
    assert!(ds.deliver(d.as_mut(), wrong, &mut injector).await.is_err());
    assert!(injector.0.is_empty());
    Ok(())
}
#[cfg(unix)]
#[test]
fn identity_reload_and_unix_file_modes() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let store = FileKeyStore::new(directory.path().join("keys"))?;
    let first = Identity::load_or_create(&store)?;
    let second = Identity::load_or_create(&store)?;
    assert_eq!(first.public, second.public);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(directory.path().join("keys/identity"))?
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        std::fs::set_permissions(
            directory.path().join("keys/identity"),
            std::fs::Permissions::from_mode(0o644),
        )?;
        assert!(store.get("identity").is_err());
    }
    Ok(())
}
#[tokio::test]
async fn listener_rejects_wildcard_and_public_interfaces() -> Result<()> {
    assert!(LanListener::bind("0.0.0.0:0".parse()?).await.is_err());
    assert!(LanListener::bind("8.8.8.8:0".parse()?).await.is_err());
    Ok(())
}

#[cfg(unix)]
#[test]
fn durable_reservations_are_atomic_across_registry_handles_and_namespaced() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let root = directory.path().join("keys");
    let registry = Registry::new(Arc::new(FileKeyStore::new(&root)?));
    let peer = registry.enroll(
        Identity::generate()?.public,
        "synthetic-room".into(),
        info("phone"),
    )?;
    let handles: Vec<_> = (0..4)
        .map(|_| {
            let root = root.clone();
            let peer = peer.clone();
            std::thread::spawn(move || -> Result<bool> {
                Registry::new(Arc::new(FileKeyStore::new(root)?))
                    .claim_command(&peer, "synthetic-command")
            })
        })
        .collect();
    let mut claimed = 0;
    for handle in handles {
        if handle.join().unwrap()? {
            claimed += 1;
        }
    }
    assert_eq!(claimed, 1);
    let reopened = Registry::new(Arc::new(FileKeyStore::new(root)?));
    assert!(!reopened.claim_command(&peer, "synthetic-command")?);
    assert!(reopened.claim_command(&peer, "dictation:synthetic-segment")?);
    assert!(reopened.claim_segment(&peer, "synthetic-segment")?);
    Ok(())
}
#[test]
fn single_receiver_lease_excludes_duplicate_daemons() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let root = directory.path().join("receiver");
    let first = voiceremote_core::storage::ReceiverLease::acquire(&root)?;
    assert!(voiceremote_core::storage::ReceiverLease::acquire(&root).is_err());
    drop(first);
    voiceremote_core::storage::ReceiverLease::acquire(&root)?;
    Ok(())
}

async fn authenticated_raw_input_never_injected(raw_packets: Vec<Vec<u8>>) -> Result<()> {
    let (mut p, mut d) = lan().await?;
    let pi = Identity::generate()?;
    let di = Identity::generate()?;
    let mut offer = Offer::issue(
        &di,
        "synthetic-account".into(),
        "synthetic-room".into(),
        &SystemClock,
    )?;
    let payload = offer.payload.clone();
    // Raw test peer deliberately bypasses the generated sender codec.
    let phone = async {
        let context = pairing::prologue(&payload)?;
        let mut state = snow::Builder::new(pairing::PATTERN.parse()?)
            .local_private_key(pi.private())?
            .prologue(&context)?
            .build_initiator()?;
        let mut packet = vec![0; 65535];
        let mut plain = vec![0; 65535];
        let n = state.write_message(&[], &mut packet)?;
        p.send(&packet[..n]).await?;
        state.read_message(&p.recv().await?, &mut plain)?;
        let n = state.write_message(&B64.decode(&payload.one_use_token)?, &mut packet)?;
        p.send(&packet[..n]).await?;
        let hash = state.get_handshake_hash().to_vec();
        let mut state = state.into_transport_mode()?;
        let mut confirmation = vec![1];
        confirmation.extend_from_slice(&hash);
        confirmation.extend_from_slice(
            encode(&info("phone"))
                .map_err(anyhow::Error::msg)?
                .as_bytes(),
        );
        let n = state.write_message(&confirmation, &mut packet)?;
        p.send(&packet[..n]).await?;
        state.read_message(&p.recv().await?, &mut plain)?;
        for raw in &raw_packets {
            let n = state.write_message(raw, &mut packet)?;
            p.send(&packet[..n]).await?;
        }
        Ok::<_, anyhow::Error>(())
    };
    let desktop = async {
        let mut pending = pairing::accept(d.as_mut(), &di, &mut offer, &SystemClock).await?;
        pending
            .confirm_local(d.as_mut(), &pending.phrase(), info("desktop"))
            .await?;
        pending.receive_confirmation(d.as_mut()).await?;
        let mut session = pending.finish(registry())?;
        let mut injector = Injector::default();
        if let Ok(message) = session.receive(d.as_mut()).await {
            session.deliver(d.as_mut(), message, &mut injector).await?;
        }
        assert!(injector.0.is_empty());
        assert!(session.check_active().is_err());
        Ok::<_, anyhow::Error>(())
    };
    let (p, d) = tokio::join!(phone, desktop);
    p?;
    d?;
    Ok(())
}
#[tokio::test]
async fn inferred_commands_without_approval_fail_and_valid_commands_are_only_reserved() -> Result<()>
{
    let (mut p, mut d) = lan().await?;
    let (_, mut session, ..) = enroll(p.as_mut(), d.as_mut(), registry(), registry()).await?;
    let mut value = serde_json::json!({"kind":"authorized_command","account_id":"synthetic-account","command_id":"synthetic-command","candidate_id":"synthetic-candidate","immutable_task_payload":{"kind":"open_resource","account_id":"synthetic-account","device_id":"desktop","resource_uri":"https://example.invalid/synthetic"},"payload_hash":"0".repeat(64),"source_tier":"inferred","activation_kind":"approval_tap","authenticated_actor":"synthetic-actor","approval_credential_class":"user_presence","risk_class":"read_display","policy_version":"synthetic-policy","granted_scope_id":"synthetic-scope","destination_id":"desktop","idempotency_key":"synthetic-command","execution_state":"queued","created_at":1,"updated_at":1});
    let missing: InnerMessage = serde_json::from_value(value.clone())?;
    let mut injector = Injector::default();
    assert!(
        session
            .deliver(d.as_mut(), missing, &mut injector)
            .await
            .is_err()
    );
    value["approval_event_id"] = "synthetic-approval".into();
    let valid: InnerMessage = decode(&value.to_string()).map_err(anyhow::Error::msg)?;
    assert_eq!(
        session
            .deliver(d.as_mut(), valid.clone(), &mut injector)
            .await?,
        Delivery::CommandReserved
    );
    assert_eq!(
        session.deliver(d.as_mut(), valid, &mut injector).await?,
        Delivery::Duplicate
    );
    assert!(injector.0.is_empty());
    Ok(())
}

#[test]
fn automatic_lan_selection_needs_no_manual_ip_and_excludes_public_interfaces() -> Result<()> {
    use voiceremote_core::transport::select_named_interface;
    let addresses = [
        "127.0.0.1".parse()?,
        "8.8.8.8".parse()?,
        "192.168.1.20".parse()?,
    ];
    let named: Vec<_> = addresses
        .iter()
        .enumerate()
        .map(|(i, ip)| (format!("eth{i}"), *ip))
        .collect();
    assert_eq!(
        select_named_interface(&named)?,
        "192.168.1.20".parse::<std::net::IpAddr>()?
    );
    assert!(select_named_interface(&named[..2]).is_err());
    Ok(())
}

#[tokio::test]
async fn all_zero_dh_results_are_rejected_before_message_two() -> Result<()> {
    for low_order in [[0u8; 32], {
        let mut key = [0u8; 32];
        key[0] = 1;
        key
    }] {
        let (mut phone, mut desktop) = lan().await?;
        let identity = Identity::generate()?;
        let mut offer = Offer::issue(
            &identity,
            "synthetic-account".into(),
            "synthetic-room".into(),
            &SystemClock,
        )?;
        phone.send(&low_order).await?;
        tokio::select! {
            result = pairing::accept(desktop.as_mut(), &identity, &mut offer, &SystemClock) => {
                assert!(result.is_err()); assert!(result.err().unwrap().to_string().to_lowercase().contains("diffie"));
            },
            _ = phone.recv() => panic!("all-zero shared secret produced handshake message two"),
        }
    }
    Ok(())
}

#[tokio::test]
async fn maximum_unicode_dictation_fits_relay_frame_cap() -> Result<()> {
    let (mut phone, mut desktop, worker) = relay().await?;
    let (mut ps, mut ds, ..) =
        enroll(phone.as_mut(), desktop.as_mut(), registry(), registry()).await?;
    let text = "🦀".repeat(16_384);
    ps.send(phone.as_mut(), &dictation(&text)).await?;
    let message = ds.receive(desktop.as_mut()).await?;
    let mut injector = Injector::default();
    ds.deliver(desktop.as_mut(), message, &mut injector).await?;
    assert_eq!(injector.0, [text]);
    worker.abort();
    Ok(())
}

struct ChannelTransport {
    tx: tokio::sync::mpsc::Sender<Vec<u8>>,
    rx: tokio::sync::mpsc::Receiver<Vec<u8>>,
}
#[async_trait]
impl Transport for ChannelTransport {
    async fn send(&mut self, bytes: &[u8]) -> Result<()> {
        self.tx
            .send(bytes.to_vec())
            .await
            .map_err(|_| anyhow::anyhow!("test channel closed"))
    }
    async fn recv(&mut self) -> Result<Vec<u8>> {
        self.rx
            .recv()
            .await
            .ok_or_else(|| anyhow::anyhow!("test channel closed"))
    }
    async fn close(&mut self) -> Result<()> {
        self.rx.close();
        Ok(())
    }
}
fn channels() -> (ChannelTransport, ChannelTransport) {
    let (at, ar) = tokio::sync::mpsc::channel(16);
    let (bt, br) = tokio::sync::mpsc::channel(16);
    (
        ChannelTransport { tx: at, rx: br },
        ChannelTransport { tx: bt, rx: ar },
    )
}
#[tokio::test(start_paused = true)]
async fn scan_after_forty_seconds_still_pairs_within_token_lifetime() -> Result<()> {
    let (mut p, mut d) = channels();
    let pi = Identity::generate()?;
    let di = Identity::generate()?;
    let mut offer = Offer::issue(
        &di,
        "synthetic-account".into(),
        "synthetic-room".into(),
        &SystemClock,
    )?;
    let payload = offer.payload.clone();
    let phone = async {
        tokio::time::sleep(Duration::from_secs(40)).await;
        pairing::initiate(&mut p, &pi, &payload, &SystemClock).await
    };
    let (p, d) = tokio::join!(
        phone,
        pairing::accept(&mut d, &di, &mut offer, &SystemClock)
    );
    assert_eq!(p?.phrase(), d?.phrase());
    Ok(())
}
#[tokio::test(start_paused = true)]
async fn reconnect_waits_over_thirty_seconds_for_phone() -> Result<()> {
    let (mut p, mut d) = channels();
    let pr = registry();
    let dr = registry();
    let (ps, ds, pi, di, _) = enroll(&mut p, &mut d, pr.clone(), dr.clone()).await?;
    let pp = ps.peer().clone();
    let dp = ds.peer().clone();
    let (mut p, mut d) = channels();
    let phone = async {
        tokio::time::sleep(Duration::from_secs(61)).await;
        pairing::resume_initiate(&mut p, &pi, &pr, &pp, "phone").await
    };
    let (p, d) = tokio::join!(
        phone,
        pairing::resume_accept(&mut d, &di, &dr, &dp, "desktop")
    );
    p?;
    d?;
    Ok(())
}
#[tokio::test(start_paused = true)]
async fn half_open_authenticated_session_expires() -> Result<()> {
    let (mut p, mut d) = channels();
    let (_, ds, ..) = enroll(&mut p, &mut d, registry(), registry()).await?;
    let (_stop, watch) = tokio::sync::watch::channel(false);
    let start = tokio::time::Instant::now();
    assert!(
        voiceremote_core::receiver::serve(ds, &mut d, &mut Injector::default(), watch)
            .await
            .is_err()
    );
    assert_eq!(start.elapsed(), voiceremote_core::receiver::IDLE_TIMEOUT);
    Ok(())
}
#[test]
fn virtual_interfaces_never_win_over_wifi() -> Result<()> {
    let interfaces = vec![
        ("docker0".into(), "172.17.0.1".parse()?),
        ("veth123".into(), "10.0.0.1".parse()?),
        ("wlan0".into(), "192.168.1.20".parse()?),
    ];
    assert_eq!(
        voiceremote_core::transport::select_named_interface(&interfaces)?,
        "192.168.1.20".parse::<std::net::IpAddr>()?
    );
    Ok(())
}
#[tokio::test]
async fn silent_peers_do_not_block_phone_and_shutdown_cancels_handshakes() -> Result<()> {
    let (mut p, mut d) = lan().await?;
    let pr = registry();
    let dr = registry();
    let (ps, ds, pi, di, _) = enroll(p.as_mut(), d.as_mut(), pr.clone(), dr.clone()).await?;
    let pp = ps.peer().clone();
    let dp = ds.peer().clone();
    let listener = LanListener::bind("127.0.0.1:0".parse()?).await?;
    let address = listener.address()?;
    let (stop, watch) = tokio::sync::watch::channel(false);
    let factory: voiceremote_core::receiver::InjectorFactory =
        Arc::new(|| Box::new(Injector::default()));
    let runner = tokio::spawn(voiceremote_core::receiver::run_lan(
        listener,
        Arc::new(di),
        dr.clone(),
        dp,
        "desktop".into(),
        factory,
        watch,
        None,
    ));
    let mut silent = Vec::new();
    for _ in 0..3 {
        silent.push(LanTransport::connect(address).await?);
    }
    let mut phone = LanTransport::connect(address).await?;
    let phone_session = tokio::time::timeout(
        Duration::from_secs(2),
        pairing::resume_initiate(&mut phone, &pi, &pr, &pp, "phone"),
    )
    .await??;
    assert!(phone_session.check_active().is_ok());
    stop.send(true)?;
    tokio::time::timeout(Duration::from_secs(1), runner).await???;
    Ok(())
}
#[tokio::test]
async fn revocation_cancels_silent_handshake_without_waiting_for_timeout() -> Result<()> {
    let (mut p, mut d) = lan().await?;
    let dr = registry();
    let (_, ds, _, di, _) = enroll(p.as_mut(), d.as_mut(), registry(), dr.clone()).await?;
    let dp = ds.peer().clone();
    let listener = LanListener::bind("127.0.0.1:0".parse()?).await?;
    let address = listener.address()?;
    let (_stop, watch) = tokio::sync::watch::channel(false);
    let factory: voiceremote_core::receiver::InjectorFactory =
        Arc::new(|| Box::new(Injector::default()));
    let runner = tokio::spawn(voiceremote_core::receiver::run_lan(
        listener,
        Arc::new(di),
        dr.clone(),
        dp.clone(),
        "desktop".into(),
        factory,
        watch,
        None,
    ));
    let _silent = LanTransport::connect(address).await?;
    dr.revoke(&dp.id)?;
    tokio::time::timeout(Duration::from_secs(1), runner).await???;
    Ok(())
}
#[test]
fn relay_backoff_is_bounded_and_increases() {
    use voiceremote_core::receiver::retry_delay;
    assert_eq!(retry_delay(0), Duration::from_millis(500));
    assert!(retry_delay(3) > retry_delay(2));
    assert_eq!(retry_delay(u32::MAX), Duration::from_secs(30));
}

struct RejectFirst {
    listener: LanListener,
    rejected: std::sync::atomic::AtomicBool,
}
#[async_trait]
impl voiceremote_core::receiver::LanAcceptor for RejectFirst {
    async fn accept(&self) -> Result<LanTransport> {
        if !self
            .rejected
            .swap(true, std::sync::atomic::Ordering::SeqCst)
        {
            voiceremote_core::bail!("synthetic non-LAN peer (100.x)");
        }
        self.listener.accept().await
    }
}
#[tokio::test]
async fn rejected_non_lan_peer_is_not_fatal_to_receiver() -> Result<()> {
    let (mut p, mut d) = lan().await?;
    let pr = registry();
    let dr = registry();
    let (ps, ds, pi, di, _) = enroll(p.as_mut(), d.as_mut(), pr.clone(), dr.clone()).await?;
    let pp = ps.peer().clone();
    let dp = ds.peer().clone();
    let listener = LanListener::bind("127.0.0.1:0".parse()?).await?;
    let address = listener.address()?;
    let (stop, watch) = tokio::sync::watch::channel(false);
    let factory: voiceremote_core::receiver::InjectorFactory =
        Arc::new(|| Box::new(Injector::default()));
    let runner = tokio::spawn(voiceremote_core::receiver::run_lan(
        RejectFirst {
            listener,
            rejected: std::sync::atomic::AtomicBool::new(false),
        },
        Arc::new(di),
        dr,
        dp,
        "desktop".into(),
        factory,
        watch,
        None,
    ));
    let mut phone = LanTransport::connect(address).await?;
    tokio::time::timeout(
        Duration::from_secs(2),
        pairing::resume_initiate(&mut phone, &pi, &pr, &pp, "phone"),
    )
    .await??;
    stop.send(true)?;
    runner.await??;
    Ok(())
}
#[tokio::test(start_paused = true)]
async fn stalled_second_handshake_step_is_timed_out() -> Result<()> {
    let (mut p, mut d) = channels();
    let pi = Identity::generate()?;
    let di = Identity::generate()?;
    let mut offer = Offer::issue(
        &di,
        "synthetic-account".into(),
        "synthetic-room".into(),
        &SystemClock,
    )?;
    let context = pairing::prologue(&offer.payload)?;
    let mut phone = pairing::noise_builder()?
        .local_private_key(pi.private())?
        .prologue(&context)?
        .build_initiator()?;
    let mut packet = [0u8; 128];
    let n = phone.write_message(&[], &mut packet)?;
    p.send(&packet[..n]).await?;
    let start = tokio::time::Instant::now();
    assert!(
        pairing::accept(&mut d, &di, &mut offer, &SystemClock)
            .await
            .is_err()
    );
    assert_eq!(start.elapsed(), pairing::HANDSHAKE_STEP_TIMEOUT);
    Ok(())
}

#[test]
fn maximum_relay_ids_and_packet_fit_workers_exact_frame_budget() -> Result<()> {
    let frame = RelayCiphertext {
        kind: RelayCiphertextKind::Ciphertext,
        account_id: "a".repeat(128),
        room_id: "r".repeat(128),
        sender_device_id: "s".repeat(128),
        ciphertext: B64.encode(vec![0; voiceremote_core::relay::PACKET_BYTES]),
    };
    let encoded = encode(&frame).map_err(anyhow::Error::msg)?;
    assert!(encoded.len() <= voiceremote_core::relay::FRAME_BYTES);
    eprintln!(
        "maximum IDs + 11000-byte Noise packet: {} JSON UTF-8 bytes (worker cap 16384)",
        encoded.len()
    );
    Ok(())
}

#[tokio::test]
async fn authenticated_malicious_peer_cannot_deliver_newline_to_injector() -> Result<()> {
    authenticated_raw_input_never_injected(vec![serde_json::to_vec(&dictation(
        "Synthetic\nsample",
    ))?])
    .await
}
#[tokio::test]
async fn malformed_or_interleaved_fragments_never_inject() -> Result<()> {
    let fragment = |total: u32, offset: u32, chunk: &[u8]| {
        let mut bytes = vec![3];
        bytes.extend_from_slice(&total.to_be_bytes());
        bytes.extend_from_slice(&offset.to_be_bytes());
        bytes.extend_from_slice(chunk);
        bytes
    };
    for packets in [
        vec![fragment(2, 1, b"{")],
        vec![fragment(1, 0, b"{}")],
        vec![fragment(2_097_153, 0, b"{")],
        vec![fragment(2, 0, b"{"), fragment(3, 1, b"}")],
        vec![fragment(2, 0, b"{"), fragment(2, 0, b"}")],
        vec![fragment(2, 0, b"{"), b"{}".to_vec()],
    ] {
        authenticated_raw_input_never_injected(packets).await?;
    }
    Ok(())
}

#[tokio::test]
async fn fifth_lan_connection_is_refused_at_low_cap() -> Result<()> {
    let (mut p, mut d) = lan().await?;
    let dr = registry();
    let (_, ds, _, di, _) = enroll(p.as_mut(), d.as_mut(), registry(), dr.clone()).await?;
    let listener = LanListener::bind("127.0.0.1:0".parse()?).await?;
    let address = listener.address()?;
    let (stop, watch) = tokio::sync::watch::channel(false);
    let factory: voiceremote_core::receiver::InjectorFactory =
        Arc::new(|| Box::new(Injector::default()));
    let runner = tokio::spawn(voiceremote_core::receiver::run_lan(
        listener,
        Arc::new(di),
        dr,
        ds.peer().clone(),
        "desktop".into(),
        factory,
        watch,
        None,
    ));
    let mut held = Vec::new();
    for _ in 0..voiceremote_core::receiver::CONNECTION_CAP {
        held.push(LanTransport::connect(address).await?);
    }
    let mut extra = LanTransport::connect(address).await?;
    assert!(
        tokio::time::timeout(Duration::from_secs(1), extra.recv())
            .await?
            .is_err()
    );
    stop.send(true)?;
    runner.await??;
    Ok(())
}
#[tokio::test]
async fn relay_keepalive_detects_half_open_websocket() -> Result<()> {
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let endpoint = format!("ws://{}", listener.local_addr()?);
    let worker = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let _socket = accept_async(stream).await.unwrap();
        std::future::pending::<()>().await;
    });
    let mut transport = RelayTransport::connect_loopback(
        &endpoint,
        RelayRoute {
            account: "synthetic-account".into(),
            room: "synthetic-room".into(),
            sender: "desktop".into(),
        },
    )
    .await?;
    tokio::time::pause();
    let start = tokio::time::Instant::now();
    let result = tokio::time::timeout(Duration::from_secs(31), transport.recv()).await?;
    assert!(
        result
            .err()
            .unwrap()
            .to_string()
            .contains("keepalive timed out")
    );
    assert!(
        start.elapsed() >= Duration::from_secs(30) && start.elapsed() < Duration::from_secs(31)
    );
    worker.abort();
    Ok(())
}
