//! Desktop session driver: encrypted focus reports plus existing bounded supervisors.
//! Derived from core receiver; kept here until core exposes a platform metadata hook.
use super::control;
use super::desktop_transport::{LanListener, RelayTransport};
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
/// Desktop transport.recv is polled alongside focus/registry timers.
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
static SAMPLER: std::sync::OnceLock<Sampler> = std::sync::OnceLock::new();
pub fn set_focus_sampler(sampler: Sampler) {
    let _ = SAMPLER.set(sampler);
}
pub type Sampler = Arc<dyn Fn() -> (bool, u64, Option<u64>) + Send + Sync>;
fn focus_report_due(previous: Option<((bool, u64), u64)>, current: (bool, u64), now: u64) -> bool {
    previous.is_none_or(|(old, at)| old != current || now.saturating_sub(at) >= 30_000)
}
pub async fn serve(
    session: Session,
    transport: &mut dyn Transport,
    injector: &mut dyn TextInjector,
    stop: watch::Receiver<bool>,
) -> Result<()> {
    let sampler = SAMPLER
        .get()
        .cloned()
        .unwrap_or_else(|| Arc::new(|| (false, 0, None)));
    let result = serve_with_sampler(
        session,
        transport,
        injector,
        stop,
        sampler,
        control::hub().clone(),
    )
    .await;
    let _ = tokio::time::timeout(Duration::from_secs(1), transport.close()).await;
    result
}
async fn serve_with_sampler(
    mut session: Session,
    transport: &mut dyn Transport,
    injector: &mut dyn TextInjector,
    stop: watch::Receiver<bool>,
    sampler: Sampler,
    hub: Arc<std::sync::Mutex<control::Hub>>,
) -> Result<()> {
    let (_registration, mut requests) = control::register(hub.clone());
    let mut capture = None;
    let mut pending_toggle: Option<(
        String,
        voiceremote_core::protocol::CaptureState,
        control::Toggle,
    )> = None;
    session.require_presentation();
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
            _=poll.tick()=>{
                session.check_active()?;
                let revoke = hub.lock().unwrap().revocations.remove(&session.peer().info.device_id);
                if let Some(reply) = revoke {
                    use voiceremote_core::protocol::{Revoke, RevokeKind};
                    let id = voiceremote_core::relay::new_room_id();
                    let report = InnerMessage::Revoke(Revoke {
                        kind: RevokeKind::Revoke, account_id: local.account_id.clone(),
                        device_id: session.peer().info.device_id.clone(), command_id: id.clone(), idempotency_key: id,
                        revoked_at: voiceremote_core::pairing::Clock::now_ms(&voiceremote_core::pairing::SystemClock)?,
                    });
                    let ok = tokio::time::timeout(Duration::from_secs(1), session.send(transport, &report)).await.is_ok_and(|r| r.is_ok());
                    let _ = reply.send(ok);
                    return Ok(());
                }
                if pending_toggle.as_ref().is_some_and(|(_, _, request)| request.expires <= tokio::time::Instant::now()) {
                    if let Some((_, _, request)) = pending_toggle.take() { let _ = request.reply.send(false); }
                }
            },
            _=tokio::time::sleep_until(idle)=>voiceremote_core::bail!("application idle timeout"),
            request=requests.recv()=>{
                let Some(request) = request else { continue; };
                if request.expires <= tokio::time::Instant::now() || capture.is_none() || pending_toggle.is_some() {
                    let _ = request.reply.send(false);
                    continue;
                }
                use voiceremote_core::protocol::{CaptureState, CaptureControl, CaptureControlKind};
                let desired = if capture == Some(CaptureState::Off) { CaptureState::Continuous } else { CaptureState::Off };
                let id = voiceremote_core::relay::new_room_id();
                let ttl_ms = request.expires.saturating_duration_since(tokio::time::Instant::now()).as_millis().clamp(1, 2000) as u64;
                let report = InnerMessage::CaptureControl(CaptureControl {
                    kind: CaptureControlKind::CaptureControl,
                    account_id: local.account_id.clone(), request_id: id.clone(),
                    target_device_id: session.peer().info.device_id.clone(), capture_state: desired.clone(), ttl_ms,
                });
                tokio::time::timeout(Duration::from_secs(2), session.send(transport, &report)).await??;
                pending_toggle = Some((id, desired, request));
            },
            _=focus.tick()=>{
                session.check_active()?;
                let sampler = sampler.clone();
                let (focused, activity, age) = tokio::task::spawn_blocking(move || sampler()).await?;
                let now = started.elapsed().as_millis() as u64;
                if !focus_report_due(previous, (focused, activity), now) { continue; }
                let report = InnerMessage::FocusReport(FocusReport { activity_age_ms: age,
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
                if let InnerMessage::TargetPrepare(request) = &message {
                    use voiceremote_core::protocol::{TargetReady, TargetReadyKind};
                    session.presentation_ready(None);
                    let ready = request.target_device_id == local.device_id && control::present(&hub, local.display_name.clone()).await;
                    session.check_active()?;
                    if ready { session.presentation_ready(Some(request.request_id.clone())); }
                    session.send(transport, &InnerMessage::TargetReady(TargetReady {
                        kind: TargetReadyKind::TargetReady, account_id: local.account_id.clone(),
                        request_id: request.request_id.clone(), target_device_id: local.device_id.clone(), ready,
                    })).await?;
                    continue;
                }
                {
                    let mut h = hub.lock().unwrap();
                    match &message {
                        InnerMessage::CaptureStateReport(report) if report.device_id == peer.info.device_id => {
                            capture = Some(report.capture_state.clone());
                            h.status.capture = capture.clone(); h.status.listening = report.listening;
                        }
                        InnerMessage::ModeState(report) if report.device_id == peer.info.device_id => h.status.mode = Some(report.mode.clone()),
                        InnerMessage::CaptureControlResult(report) if report.device_id == peer.info.device_id => {
                            if pending_toggle.as_ref().is_some_and(|(id, desired, request)| *id == report.request_id && *desired == report.capture_state && request.expires > tokio::time::Instant::now()) {
                                let (_, _, request) = pending_toggle.take().unwrap();
                                let _ = request.reply.send(report.outcome == voiceremote_core::protocol::CaptureControlResultOutcome::Applied);
                            }
                        }
                        _ => {}
                    }
                }
                // Do not print errors from decoding or field data. Native
                // injection errors are fixed, content-free messages.
                if session.deliver(transport, message, injector).await? == Delivery::Revoked {
                    return Ok(());
                }
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
/// Both paths stay available. Only the authenticated phone chooses its path;
/// application messages are never replayed when a connection changes.
pub async fn run_paths(
    listener: Option<LanListener>,
    client: Option<RelayClient>,
    identity: Arc<Identity>,
    registry: Registry,
    peer: Peer,
    local: String,
    injectors: InjectorFactory,
    stop: watch::Receiver<bool>,
    mut initial: Option<(Session, Box<dyn Transport>)>,
    initial_relay: bool,
) -> Result<()> {
    let lan_initial = if !initial_relay { initial.take() } else { None };
    let lan = async {
        if let Some(listener) = listener {
            run_lan(
                listener,
                identity.clone(),
                registry.clone(),
                peer.clone(),
                local.clone(),
                injectors.clone(),
                stop.clone(),
                lan_initial,
            )
            .await
        } else {
            std::future::pending().await
        }
    };
    let relay = async {
        if let Some(client) = client {
            if let Some((session, mut transport)) = initial {
                let _ = serve(
                    session,
                    transport.as_mut(),
                    injectors().as_mut(),
                    stop.clone(),
                )
                .await;
            }
            run_relay(
                client,
                identity.clone(),
                registry.clone(),
                peer.clone(),
                local.clone(),
                injectors.clone(),
                stop.clone(),
            )
            .await
        } else {
            std::future::pending().await
        }
    };
    tokio::select! { result = lan => result, result = relay => result, _ = stopped(stop.clone()) => Ok(()) }
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
    struct Injector(
        Arc<Mutex<Vec<String>>>,
        Option<voiceremote_core::InsertionFailure>,
        Arc<std::sync::atomic::AtomicUsize>,
    );
    impl TextInjector for Injector {
        fn insert_text(&mut self, text: &str) -> Result<()> {
            self.2.fetch_add(1, Ordering::SeqCst);
            if self.1 != Some(voiceremote_core::InsertionFailure::NotStarted) {
                self.0.lock().unwrap().push(text.into());
            }
            match self.1 {
                Some(failure) => Err(failure.into()),
                None => Ok(()),
            }
        }
    }
    #[tokio::test]
    async fn encrypted_session_reports_focus_changes_without_contents_and_delivers_fragmented_literal_text()
    -> Result<()> {
        exercise_session(None).await
    }
    #[tokio::test]
    async fn refused_before_input_reports_unavailable_and_keeps_session_open() -> Result<()> {
        exercise_session(Some(voiceremote_core::InsertionFailure::NotStarted)).await
    }
    #[tokio::test]
    async fn unconfirmed_paste_reports_error_and_replay_never_reinserts() -> Result<()> {
        exercise_session(Some(voiceremote_core::InsertionFailure::Unconfirmed)).await
    }
    #[tokio::test]
    async fn stalled_tray_prevents_insertion_until_display_ready() -> Result<()> {
        exercise_session_with_presentation(None, true, false).await
    }
    async fn exercise_session(failure: Option<voiceremote_core::InsertionFailure>) -> Result<()> {
        exercise_session_with_presentation(failure, false, false).await
    }
    #[tokio::test]
    async fn local_revoke_notifies_the_authenticated_phone_before_erasure() -> Result<()> {
        exercise_session_with_presentation(None, false, true).await
    }
    async fn exercise_session_with_presentation(
        failure: Option<voiceremote_core::InsertionFailure>,
        stalled: bool,
        local_notice: bool,
    ) -> Result<()> {
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
        let sampler: Sampler = Arc::new(move || (sample.load(Ordering::SeqCst), 1234, Some(0)));
        let inserted = Arc::new(Mutex::new(Vec::new()));
        let injected = inserted.clone();
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let called = calls.clone();
        let (_stop, watch) = watch::channel(false);
        let hub = Arc::new(std::sync::Mutex::new(control::Hub::default()));
        hub.lock().unwrap().presentation_required = stalled;
        let observed = hub.clone();
        let task = tokio::spawn(async move {
            serve_with_sampler(
                ds,
                &mut desktop,
                &mut Injector(injected, failure, called),
                watch,
                sampler,
                hub,
            )
            .await
        });
        let message =
            tokio::time::timeout(Duration::from_secs(3), ps.receive(&mut phone)).await??;
        let InnerMessage::FocusReport(first) = message else {
            panic!("missing initial focus report")
        };
        assert!(first.text_field_focused);
        assert_eq!(first.last_activity_at, 1234);
        assert_eq!(first.device_id, "desktop");
        assert_eq!(serde_json::to_value(&first)?.as_object().unwrap().len(), 6);
        // Prove a local hotkey request reaches the authenticated encrypted session.
        ps.send(
            &mut phone,
            &InnerMessage::CaptureStateReport(CaptureStateReport {
                listening: None,
                kind: CaptureStateReportKind::CaptureState,
                account_id: "synthetic-account".into(),
                device_id: "phone".into(),
                capture_state: CaptureState::Off,
            }),
        )
        .await?;
        for _ in 0..100 {
            if observed.lock().unwrap().status.capture.is_some() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let control_hub = observed.clone();
        let toggle = tokio::spawn(async move { control::toggle(&control_hub).await });
        let request =
            tokio::time::timeout(Duration::from_secs(3), ps.receive(&mut phone)).await??;
        let InnerMessage::CaptureControl(request) = request else {
            panic!("capture request expected")
        };
        assert_eq!(request.capture_state, CaptureState::Continuous);
        assert_eq!(request.target_device_id, "phone");
        assert!(!toggle.is_finished(), "write is not phone confirmation");
        ps.send(
            &mut phone,
            &InnerMessage::CaptureControlResult(voiceremote_core::protocol::CaptureControlResult {
                kind: voiceremote_core::protocol::CaptureControlResultKind::CaptureControlResult,
                account_id: "synthetic-account".into(),
                device_id: "phone".into(),
                request_id: request.request_id,
                capture_state: CaptureState::Continuous,
                outcome: voiceremote_core::protocol::CaptureControlResultOutcome::Applied,
            }),
        )
        .await?;
        toggle.await??;
        ps.send(
            &mut phone,
            &InnerMessage::CaptureStateReport(CaptureStateReport {
                listening: None,
                kind: CaptureStateReportKind::CaptureState,
                account_id: "synthetic-account".into(),
                device_id: "other-phone".into(),
                capture_state: CaptureState::Continuous,
            }),
        )
        .await?;
        ps.send(
            &mut phone,
            &InnerMessage::ModeState(ModeState {
                kind: ModeStateKind::Mode,
                account_id: "synthetic-account".into(),
                device_id: "phone".into(),
                mode: Mode::AiControl,
            }),
        )
        .await?;
        for _ in 0..100 {
            if observed.lock().unwrap().status.mode.is_some() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(observed.lock().unwrap().status.mode, Some(Mode::AiControl));
        // Reports naming a different device cannot alter the displayed capture state.
        // Sending a request must not optimistically change reported mic state.
        assert_eq!(
            observed.lock().unwrap().status.capture,
            Some(CaptureState::Off)
        );
        let literal = "Synthetic 🦀 ".repeat(1000);
        let dictation = InnerMessage::DictationText(DictationText {
            preparation_id: Some("prepare-fixture".into()),
            kind: DictationTextKind::DictationText,
            account_id: "synthetic-account".into(),
            segment_id: "synthetic-segment".into(),
            revision: 1,
            state: DictationTextState::Committed,
            target_device_id: "desktop".into(),
            text: literal.clone(),
        });
        // Presentation is explicitly acknowledged before the segment is eligible.
        ps.send(
            &mut phone,
            &InnerMessage::TargetPrepare(voiceremote_core::protocol::TargetPrepare {
                kind: voiceremote_core::protocol::TargetPrepareKind::TargetPrepare,
                account_id: "synthetic-account".into(),
                request_id: "prepare-fixture".into(),
                target_device_id: "desktop".into(),
            }),
        )
        .await?;
        if stalled {
            for _ in 0..100 {
                if observed.lock().unwrap().status.flash > 0 {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            ps.send(&mut phone, &dictation).await?;
            tokio::time::sleep(Duration::from_millis(100)).await;
            assert_eq!(
                calls.load(Ordering::SeqCst),
                0,
                "insertion overtook stalled presentation"
            );
            let sequence = observed.lock().unwrap().status.flash;
            control::presented(&observed, sequence, true);
        }
        assert!(matches!(
            ps.receive(&mut phone).await?,
            InnerMessage::TargetReady(voiceremote_core::protocol::TargetReady { ready: true, .. })
        ));
        if !stalled {
            ps.send(&mut phone, &dictation).await?;
        }
        if let Some(failure) = failure {
            for attempt in 1..=2 {
                let message =
                    tokio::time::timeout(Duration::from_secs(3), ps.receive(&mut phone)).await??;
                let InnerMessage::DictationOutcome(report) = message else {
                    panic!("missing insertion status")
                };
                assert_eq!(report.segment_id, "synthetic-segment");
                let not_started = failure == voiceremote_core::InsertionFailure::NotStarted;
                assert_eq!(
                    report.outcome,
                    if not_started {
                        voiceremote_core::protocol::DictationOutcomeOutcome::Unavailable
                    } else {
                        voiceremote_core::protocol::DictationOutcomeOutcome::Unconfirmed
                    }
                );
                assert_eq!(
                    calls.load(Ordering::SeqCst),
                    if not_started { attempt } else { 1 }
                );
                if attempt == 1 {
                    ps.send(&mut phone, &dictation).await?;
                }
            }
            assert_eq!(
                inserted.lock().unwrap().len(),
                usize::from(failure != voiceremote_core::InsertionFailure::NotStarted)
            );
            dr.revoke(&peer)?;
            assert!(
                tokio::time::timeout(Duration::from_secs(2), task)
                    .await??
                    .is_err()
            );
            return Ok(());
        }
        assert!(matches!(
            ps.receive(&mut phone).await?,
            InnerMessage::DictationOutcome(voiceremote_core::protocol::DictationOutcome {
                outcome: voiceremote_core::protocol::DictationOutcomeOutcome::Inserted,
                ..
            })
        ));
        // Keep Session::receive pinned while checking silence; cancelling and
        // recreating it would poison the session and invalidate this test.
        let message = {
            let next = ps.receive(&mut phone);
            tokio::pin!(next);
            assert!(
                tokio::time::timeout(Duration::from_millis(1200), &mut next)
                    .await
                    .is_err(),
                "unchanged focus must not produce a one-second report"
            );
            focused.store(false, Ordering::SeqCst);
            tokio::time::timeout(Duration::from_secs(3), &mut next).await??
        };
        let InnerMessage::FocusReport(second) = message else {
            panic!("missing changed focus report")
        };
        assert!(!second.text_field_focused);
        assert_eq!(
            second.last_activity_at, 1234,
            "polling must not invent user activity"
        );
        assert_eq!(*inserted.lock().unwrap(), [literal]);
        assert!(observed.lock().unwrap().status.flash > 0);
        assert_eq!(
            observed.lock().unwrap().status.destination.as_deref(),
            Some("desktop")
        );
        if local_notice {
            let hub = observed.clone();
            let notification =
                tokio::spawn(async move { control::notify_revocation(&hub, "phone").await });
            let notice =
                tokio::time::timeout(Duration::from_secs(3), ps.receive(&mut phone)).await??;
            assert!(
                matches!(notice, InnerMessage::Revoke(Revoke { device_id, .. }) if device_id == "phone")
            );
            assert!(notification.await?);
            assert!(task.await?.is_ok());
            dr.revoke(&peer)?;
            return Ok(());
        }
        dr.revoke(&peer)?;
        assert!(
            tokio::time::timeout(Duration::from_secs(2), task)
                .await??
                .is_err()
        );
        Ok(())
    }
}
