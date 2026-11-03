//! Windows session driver: encrypted focus reports plus existing bounded supervisors.
//! Derived from core receiver; kept here until core exposes a platform metadata hook.
use super::windows_transport::{LanListener, RelayTransport};
use std::{future::Future, sync::Arc, time::Duration};
use tokio::{sync::watch, task::JoinSet};
use voiceremote_core::protocol::{FocusReport, FocusReportKind, InnerMessage};
use voiceremote_core::{
    Result, TextInjector, pairing,
    relay::RelayClient,
    session::{Delivery, Session},
    storage::{Identity, Peer, Registry},
    transport::Transport,
};

pub const CONNECTION_CAP: usize = 4;
pub const IDLE_TIMEOUT: Duration = Duration::from_secs(90);
const POLL: Duration = Duration::from_millis(250);
pub type InjectorFactory = Arc<dyn Fn() -> Box<dyn TextInjector> + Send + Sync>;
pub async fn stopped(mut stop: watch::Receiver<bool>) {
    if !*stop.borrow() {
        let _ = stop.wait_for(|value| *value).await;
    }
}
/// Keeps futures alive while polling; never restarts a partially consumed frame.
async fn guarded<T>(
    future: impl Future<Output = Result<T>>,
    registry: &Registry,
    peer: &Peer,
    stop: watch::Receiver<bool>,
) -> Result<T> {
    tokio::pin!(future);
    let mut poll = tokio::time::interval(POLL);
    loop {
        tokio::select! {
            result=&mut future=>return result,
            _=poll.tick()=>registry.require(peer)?,
            _=stopped(stop.clone())=>voiceremote_core::bail!("receiver stopped"),
        }
    }
}
/// First raw packet is staged outside Session::receive: cancelling that method
/// would poison the session and lose fragment state. Only cancellation-safe
/// Windows transport.recv is polled alongside focus/registry timers.
struct Prefetched<'a> {
    first: Option<Vec<u8>>,
    inner: &'a mut dyn Transport,
}
#[async_trait::async_trait]
impl Transport for Prefetched<'_> {
    async fn send(&mut self, packet: &[u8]) -> Result<()> {
        self.inner.send(packet).await
    }
    async fn recv(&mut self) -> Result<Vec<u8>> {
        if let Some(packet) = self.first.take() {
            Ok(packet)
        } else {
            self.inner.recv().await
        }
    }
    async fn close(&mut self) -> Result<()> {
        self.inner.close().await
    }
}
type Sampler = Arc<dyn Fn() -> (bool, u64) + Send + Sync>;
pub async fn serve(
    session: Session,
    transport: &mut dyn Transport,
    injector: &mut dyn TextInjector,
    stop: watch::Receiver<bool>,
) -> Result<()> {
    let sampler: Sampler = Arc::new(|| {
        #[cfg(windows)]
        {
            let snapshot = voiceremote_inject_windows::focus_snapshot();
            (snapshot.text_field_focused, snapshot.last_activity_at)
        }
        #[cfg(not(windows))]
        {
            (false, 0)
        }
    });
    let result = serve_with_sampler(session, transport, injector, stop, sampler).await;
    let _ = tokio::time::timeout(Duration::from_secs(1), transport.close()).await;
    result
}
async fn serve_with_sampler(
    mut session: Session,
    transport: &mut dyn Transport,
    injector: &mut dyn TextInjector,
    stop: watch::Receiver<bool>,
    sampler: Sampler,
) -> Result<()> {
    let local = session
        .registry()
        .local_info()?
        .ok_or_else(|| voiceremote_core::anyhow!("local device not enrolled"))?;
    let mut focus = tokio::time::interval(Duration::from_secs(1));
    focus.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut poll = tokio::time::interval(POLL);
    let mut idle = tokio::time::Instant::now() + IDLE_TIMEOUT;
    let started = tokio::time::Instant::now();
    let mut previous = None;
    loop {
        tokio::select! {
            biased;
            _=stopped(stop.clone())=>return Ok(()),
            _=poll.tick()=>session.check_active()?,
            _=tokio::time::sleep_until(idle)=>voiceremote_core::bail!("application idle timeout"),
            _=focus.tick()=>{
                session.check_active()?;
                let sampler = sampler.clone();
                let (focused, activity) = tokio::task::spawn_blocking(move || sampler()).await?;
                let now = started.elapsed().as_millis() as u64;
                if !voiceremote_inject_windows::policy::focus_report_due(previous, (focused, activity), now) { continue; }
                let report = InnerMessage::FocusReport(FocusReport {
                    kind: FocusReportKind::FocusReport,
                    account_id: local.account_id.clone(), device_id: local.device_id.clone(),
                    text_field_focused: focused, last_activity_at: activity,
                });
                let registry = session.registry().clone();
                let peer = session.peer().clone();
                guarded(session.send(transport, &report), &registry, &peer, stop.clone()).await?;
                previous = Some(((focused, activity), now));
            },
            packet=transport.recv()=>{
                let registry = session.registry().clone();
                let peer = session.peer().clone();
                let mut input = Prefetched { first: Some(packet?), inner: transport };
                let message = guarded(async {
                    Ok(tokio::time::timeout(IDLE_TIMEOUT, session.receive(&mut input)).await??)
                }, &registry, &peer, stop.clone()).await?;
                idle = tokio::time::Instant::now() + IDLE_TIMEOUT;
                // Do not print errors from decoding or field data. Native
                // injection errors are fixed, content-free messages.
                if session.deliver(transport, message, injector).await? == Delivery::Revoked { return Ok(()); }
            },
        }
    }
}
pub async fn run_lan(
    listener: LanListener,
    identity: Arc<Identity>,
    registry: Registry,
    peer: Peer,
    local: String,
    injectors: InjectorFactory,
    stop: watch::Receiver<bool>,
    initial: Option<(Session, Box<dyn Transport>)>,
) -> Result<()> {
    let mut tasks = JoinSet::new();
    if let Some((session, mut transport)) = initial {
        let stop = stop.clone();
        let injectors = injectors.clone();
        tasks.spawn(async move {
            let _ = serve(session, transport.as_mut(), injectors().as_mut(), stop).await;
            let _ = tokio::time::timeout(Duration::from_secs(1), transport.close()).await;
        });
    }
    let mut poll = tokio::time::interval(POLL);
    loop {
        tokio::select! {
            _=stopped(stop.clone())=>break,
            _=poll.tick()=>{if registry.require(&peer).is_err(){break;}},
            _=tasks.join_next(),if !tasks.is_empty()=>{},
            accepted=listener.accept()=>{
                // A filtered non-LAN socket and per-connection errors never end the listener.
                let Ok(mut transport)=accepted else {tokio::time::sleep(Duration::from_millis(25)).await;continue;};
                if tasks.len()>=CONNECTION_CAP {let _=transport.close().await;continue;}
                let identity=identity.clone();let registry=registry.clone();let peer=peer.clone();let local=local.clone();let stop=stop.clone();let injectors=injectors.clone();
                tasks.spawn(async move {
                    let handshake=async {Ok(tokio::time::timeout(pairing::HANDSHAKE_STEP_TIMEOUT,pairing::resume_accept(&mut transport,&identity,&registry,&peer,&local)).await??)};
                    if let Ok(session)=guarded(handshake,&registry,&peer,stop.clone()).await {let _=serve(session,&mut transport,injectors().as_mut(),stop).await;}
                    let _=tokio::time::timeout(Duration::from_secs(1),transport.close()).await;
                });
            }
        }
    }
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
    Ok(())
}
pub fn retry_delay(attempt: u32) -> Duration {
    Duration::from_millis(500u64.saturating_mul(1u64 << attempt.min(6)))
        .min(Duration::from_secs(30))
}
pub async fn run_relay(
    client: RelayClient,
    identity: Arc<Identity>,
    registry: Registry,
    peer: Peer,
    local: String,
    injectors: InjectorFactory,
    stop: watch::Receiver<bool>,
) -> Result<()> {
    let mut attempt = 0;
    loop {
        if *stop.borrow() || registry.require(&peer).is_err() {
            return Ok(());
        }
        if let Ok(mut transport) = guarded(
            RelayTransport::connect(&client),
            &registry,
            &peer,
            stop.clone(),
        )
        .await
        {
            // No 30s deadline around an idle, healthy relay waiting for the phone.
            if let Ok(session) = guarded(
                pairing::resume_accept(&mut transport, &identity, &registry, &peer, &local),
                &registry,
                &peer,
                stop.clone(),
            )
            .await
            {
                attempt = 0;
                let _ = serve(session, &mut transport, injectors().as_mut(), stop.clone()).await;
            }
            let _ = tokio::time::timeout(Duration::from_secs(1), transport.close()).await;
        }
        if *stop.borrow() || registry.require(&peer).is_err() {
            return Ok(());
        }
        let delay = retry_delay(attempt);
        attempt = attempt.saturating_add(1);
        // Backoff is cancellable and revocation remains responsive while offline.
        let _ = guarded(
            async {
                tokio::time::sleep(delay).await;
                Ok(())
            },
            &registry,
            &peer,
            stop.clone(),
        )
        .await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        collections::HashMap,
        sync::{
            Mutex,
            atomic::{AtomicBool, Ordering},
        },
    };
    use voiceremote_core::{
        pairing::{Offer, SystemClock},
        protocol::*,
        storage::KeyStore,
    };
    use zeroize::Zeroizing;
    #[derive(Default)]
    struct Memory(Mutex<HashMap<String, Vec<u8>>>);
    impl KeyStore for Memory {
        fn get(&self, key: &str) -> Result<Option<Zeroizing<Vec<u8>>>> {
            Ok(self.0.lock().unwrap().get(key).cloned().map(Zeroizing::new))
        }
        fn put(&self, key: &str, value: &[u8]) -> Result<()> {
            self.0.lock().unwrap().insert(key.into(), value.into());
            Ok(())
        }
        fn delete(&self, key: &str) -> Result<()> {
            self.0.lock().unwrap().remove(key);
            Ok(())
        }
        fn reserve(&self, key: &str) -> Result<bool> {
            let mut data = self.0.lock().unwrap();
            if data.contains_key(key) {
                return Ok(false);
            }
            data.insert(key.into(), vec![1]);
            Ok(true)
        }
    }
    struct Injector(Arc<Mutex<Vec<String>>>);
    impl TextInjector for Injector {
        fn insert_text(&mut self, text: &str) -> Result<()> {
            self.0.lock().unwrap().push(text.into());
            Ok(())
        }
    }
    #[tokio::test]
    async fn encrypted_session_reports_focus_changes_without_contents_and_delivers_fragmented_literal_text()
    -> Result<()> {
        let listener = LanListener::bind("127.0.0.1:0".parse()?).await?;
        let mut phone =
            voiceremote_core::transport::LanTransport::connect(listener.address()?).await?;
        let mut desktop = listener.accept().await?;
        let pi = Identity::generate()?;
        let di = Identity::generate()?;
        let pr = Registry::new(Arc::new(Memory::default()));
        let dr = Registry::new(Arc::new(Memory::default()));
        let mut offer = Offer::issue(
            &di,
            "synthetic-account".into(),
            "synthetic-room".into(),
            &SystemClock,
        )?;
        let payload = offer.payload.clone();
        let (p, d) = tokio::join!(
            pairing::initiate(&mut phone, &pi, &payload, &SystemClock),
            pairing::accept(&mut desktop, &di, &mut offer, &SystemClock)
        );
        let (mut p, mut d) = (p?, d?);
        let phrase = p.phrase();
        p.confirm_local(
            &mut phone,
            &phrase,
            crate::info("synthetic-account", "phone"),
        )
        .await?;
        d.confirm_local(
            &mut desktop,
            &phrase,
            crate::info("synthetic-account", "desktop"),
        )
        .await?;
        let (a, b) = tokio::join!(
            p.receive_confirmation(&mut phone),
            d.receive_confirmation(&mut desktop)
        );
        a?;
        b?;
        let mut ps = p.finish(pr)?;
        let ds = d.finish(dr.clone())?;
        let peer = ds.peer().id.clone();
        let focused = Arc::new(AtomicBool::new(true));
        let sample = focused.clone();
        let sampler: Sampler = Arc::new(move || (sample.load(Ordering::SeqCst), 1234));
        let inserted = Arc::new(Mutex::new(Vec::new()));
        let injected = inserted.clone();
        let (_stop, watch) = watch::channel(false);
        let task = tokio::spawn(async move {
            serve_with_sampler(ds, &mut desktop, &mut Injector(injected), watch, sampler).await
        });
        let message =
            tokio::time::timeout(Duration::from_secs(3), ps.receive(&mut phone)).await??;
        let InnerMessage::FocusReport(first) = message else {
            panic!("missing initial focus report")
        };
        assert!(first.text_field_focused);
        assert_eq!(first.last_activity_at, 1234);
        assert_eq!(first.device_id, "desktop");
        assert_eq!(serde_json::to_value(&first)?.as_object().unwrap().len(), 5);
        let literal = "Synthetic 🦀 ".repeat(1000);
        ps.send(
            &mut phone,
            &InnerMessage::DictationText(DictationText {
                kind: DictationTextKind::DictationText,
                account_id: "synthetic-account".into(),
                segment_id: "synthetic-segment".into(),
                revision: 1,
                state: DictationTextState::Committed,
                target_device_id: "desktop".into(),
                text: literal.clone(),
            }),
        )
        .await?;
        // Keep Session::receive pinned while checking silence; cancelling and
        // recreating it would poison the session and invalidate this test.
        let next = ps.receive(&mut phone);
        tokio::pin!(next);
        assert!(
            tokio::time::timeout(Duration::from_millis(1200), &mut next)
                .await
                .is_err(),
            "unchanged focus must not produce a one-second report"
        );
        focused.store(false, Ordering::SeqCst);
        let message = tokio::time::timeout(Duration::from_secs(3), &mut next).await??;
        let InnerMessage::FocusReport(second) = message else {
            panic!("missing changed focus report")
        };
        assert!(!second.text_field_focused);
        assert_eq!(
            second.last_activity_at, 1234,
            "polling must not invent user activity"
        );
        assert_eq!(*inserted.lock().unwrap(), [literal]);
        dr.revoke(&peer)?;
        assert!(
            tokio::time::timeout(Duration::from_secs(2), task)
                .await??
                .is_err()
        );
        Ok(())
    }
}
