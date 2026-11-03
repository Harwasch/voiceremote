//! Literal Linux dictation boundary. REQ-16, REQ-18–20, REQ-57.
#![cfg(target_os = "linux")]
mod focus;
mod keymap;
mod native;
mod paste;
mod portal;
mod x11;

use std::{path::PathBuf, sync::mpsc};
use voiceremote_core::{Result, TextInjector, anyhow, ensure};

/// Unknown deliberately maps to false for the phone's Auto selection.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Focus {
    Editable,
    Terminal,
    NotEditable,
    Password,
    Unknown,
}
impl Focus {
    pub fn text_field_focused(self) -> bool {
        matches!(self, Self::Editable | Self::Terminal)
    }
}

/// Content-free focus metadata sampled by the encrypted session driver.
#[derive(Clone, Copy, Debug, Default)]
pub struct FocusSnapshot {
    pub text_field_focused: bool,
    pub last_activity_at: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Session {
    Wayland,
    X11,
    Unknown,
}
impl Session {
    pub fn detect() -> Self {
        // Never use XTest into Xwayland as a Wayland input backend.
        Self::from_environment(
            std::env::var("XDG_SESSION_TYPE").ok().as_deref(),
            std::env::var_os("WAYLAND_DISPLAY").is_some(),
            std::env::var_os("DISPLAY").is_some(),
        )
    }
    fn from_environment(session: Option<&str>, wayland: bool, display: bool) -> Self {
        match session {
            Some("wayland") => Self::Wayland,
            Some("x11") => Self::X11,
            _ if wayland => Self::Wayland,
            _ if display => Self::X11,
            _ => Self::Unknown,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Backend {
    PortalEis,
    PortalPaste,
    Uinput,
    Wtype,
    Dotool,
    XTestPaste,
    XTestType,
}
fn candidates(session: Session) -> &'static [Backend] {
    use Backend::*;
    match session {
        Session::Wayland => &[PortalEis, PortalPaste, Uinput, Wtype, Dotool],
        Session::X11 => &[XTestPaste, XTestType],
        Session::Unknown => &[],
    }
}

// Only static, reviewed messages cross the OS boundary. Native errors, helper
// stderr, field names and payloads are deliberately excluded from logs/errors.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Reason {
    PortalUnavailable,
    PermissionDenied,
    EisUnavailable,
    ClipboardUnavailable,
    DisplayUnavailable,
    UnsupportedLayout,
    ModifiersHeld,
    HelperUnavailable,
    InputFailed,
    ClipboardRestoreFailed,
    DeliveryUnconfirmed,
    PendingPaste,
    FocusUnknown,
    FocusChanged,
}
#[derive(Debug)]
pub(crate) enum Attempt {
    Unavailable(Reason),
    Failed(Reason),
    Inserted,
}
pub(crate) trait Platform {
    fn focus(&mut self) -> Focus;
    fn attempt(&mut self, backend: Backend, text: &str) -> Attempt;
}

/// Reject rather than sanitize: sanitizing can silently alter dictated text.
pub fn validate_text(text: &str) -> Result<()> {
    ensure!(
        text.chars().count() <= 16_384,
        "dictation exceeds protocol limit"
    );
    ensure!(
        !text
            .chars()
            .any(|c| c.is_control() || matches!(c, '\u{2028}' | '\u{2029}')),
        "dictation contains a forbidden control or separator"
    );
    Ok(())
}

fn insert(platform: &mut impl Platform, session: Session, text: &str) -> Result<()> {
    insert_checked(platform, session, text).map_err(|error| {
        if error
            .downcast_ref::<voiceremote_core::InsertionFailure>()
            .is_some()
        {
            error
        } else {
            error.context(voiceremote_core::InsertionFailure::NotStarted)
        }
    })
}
fn insert_checked(platform: &mut impl Platform, session: Session, text: &str) -> Result<()> {
    validate_text(text)?;
    if text.is_empty() {
        return Ok(());
    }
    match platform.focus() {
        Focus::Password => return Err(anyhow!("password field: injection denied")),
        Focus::NotEditable => return Err(anyhow!("focused object is not editable")),
        Focus::Unknown => {
            return Err(anyhow!(
                "focus/password role could not be determined; insertion refused"
            ));
        }
        _ => {}
    }
    let mut last = None;
    for &backend in candidates(session) {
        match platform.attempt(backend, text) {
            Attempt::Inserted => {
                tracing::info!(?backend, "Linux input delivered");
                return Ok(());
            }
            Attempt::Unavailable(reason) => {
                tracing::info!(
                    ?backend,
                    ?reason,
                    "Linux input backend unavailable; trying next"
                );
                last = Some(reason);
            }
            Attempt::Failed(reason) => {
                tracing::warn!(
                    ?backend,
                    ?reason,
                    "Linux input failed; delivery may be partial"
                );
                return Err(anyhow!(
                    "Linux input failed: {reason:?}; delivery may be partial; do not automatically retry"
                ).context(voiceremote_core::InsertionFailure::Unconfirmed));
            }
        }
    }
    Err(anyhow!(
        "no usable Linux input backend ({last:?}); check desktop portal permissions, display and optional helper availability"
    ))
}

enum Request {
    Insert(String, mpsc::SyncSender<Result<()>>),
    Focus(mpsc::SyncSender<Focus>),
}
/// Clone shares one serialized worker and one portal grant/session. Creating this
/// handle does not open the display or request permission until an insertion.
#[derive(Clone)]
pub struct LinuxInjector {
    send: mpsc::Sender<Request>,
}
impl LinuxInjector {
    pub fn new(state_dir: PathBuf) -> Self {
        let (send, receive) = mpsc::channel();
        std::thread::spawn(move || {
            let mut platform = native::Native::new(state_dir);
            let session = Session::detect();
            while let Ok(request) = receive.recv() {
                match request {
                    Request::Insert(text, reply) => {
                        // Also serialize separate handles/receiver factories in this process.
                        static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
                        let result = LOCK
                            .lock()
                            .map_err(|_| anyhow!("Linux input lock unavailable"))
                            .and_then(|_guard| insert(&mut platform, session, &text));
                        let _ = reply.send(result);
                    }
                    Request::Focus(reply) => {
                        let _ = reply.send(platform.reported_focus());
                    }
                }
            }
        });
        Self { send }
    }
    pub fn focus_snapshot(&self) -> FocusSnapshot {
        let focus = self.focus_report();
        let activity = if focus.text_field_focused() {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .map(|r| r.block_on(focus::activity()))
                .unwrap_or(0)
        } else {
            0
        };
        FocusSnapshot {
            text_field_focused: focus.text_field_focused(),
            last_activity_at: activity,
        }
    }
    pub fn focus_report(&self) -> Focus {
        let (send, receive) = mpsc::sync_channel(1);
        if self.send.send(Request::Focus(send)).is_err() {
            return Focus::Unknown;
        }
        receive
            .recv_timeout(std::time::Duration::from_millis(500))
            .unwrap_or(Focus::Unknown)
    }
}
impl TextInjector for LinuxInjector {
    fn insert_text(&mut self, text: &str) -> Result<()> {
        validate_text(text)
            .map_err(|e| e.context(voiceremote_core::InsertionFailure::NotStarted))?;
        let (send, receive) = mpsc::sync_channel(1);
        self.send
            .send(Request::Insert(text.into(), send))
            .map_err(|_| anyhow!(voiceremote_core::InsertionFailure::NotStarted))?;
        receive
            .recv()
            .map_err(|_| anyhow!(voiceremote_core::InsertionFailure::Unconfirmed))?
    }
    fn insert_text_async<'a>(
        &'a mut self,
        text: &'a str,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<()>> + Send + 'a>> {
        Box::pin(async move {
            validate_text(text)
                .map_err(|e| e.context(voiceremote_core::InsertionFailure::NotStarted))?;
            let mut worker = self.clone();
            let text = text.to_owned();
            tokio::task::spawn_blocking(move || worker.insert_text(&text))
                .await
                .map_err(|_| anyhow!(voiceremote_core::InsertionFailure::Unconfirmed))?
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fake {
        focus: Focus,
        attempts: Vec<Backend>,
        replies: std::collections::VecDeque<Attempt>,
    }
    impl Platform for Fake {
        fn focus(&mut self) -> Focus {
            self.focus
        }
        fn attempt(&mut self, backend: Backend, _: &str) -> Attempt {
            self.attempts.push(backend);
            self.replies
                .pop_front()
                .unwrap_or(Attempt::Unavailable(Reason::HelperUnavailable))
        }
    }
    fn fake() -> Fake {
        Fake {
            focus: Focus::Editable,
            attempts: vec![],
            replies: Default::default(),
        }
    }
    #[test]
    fn session_detection_never_mistakes_xwayland_for_x11() {
        assert_eq!(
            Session::from_environment(Some("wayland"), true, true),
            Session::Wayland
        );
        assert_eq!(
            Session::from_environment(None, true, true),
            Session::Wayland
        );
        assert_eq!(
            Session::from_environment(Some("x11"), false, true),
            Session::X11
        );
        assert_eq!(
            Session::from_environment(None, false, false),
            Session::Unknown
        );
    }
    #[test]
    fn chooser_order_and_no_false_success() {
        for session in [Session::Wayland, Session::X11, Session::Unknown] {
            let mut p = fake();
            assert!(insert(&mut p, session, "synthetic fixture").is_err());
            assert_eq!(p.attempts, candidates(session));
        }
    }
    #[test]
    fn unconfirmed_delivery_keeps_claim_and_never_tries_another_backend() {
        let mut p = fake();
        p.replies.extend([
            Attempt::Failed(Reason::DeliveryUnconfirmed),
            Attempt::Inserted,
        ]);
        let error = insert(&mut p, Session::X11, "synthetic").unwrap_err();
        assert_eq!(
            error.downcast_ref::<voiceremote_core::InsertionFailure>(),
            Some(&voiceremote_core::InsertionFailure::Unconfirmed)
        );
        assert_eq!(p.attempts, [Backend::XTestPaste]);
    }
    #[test]
    fn refused_before_input_is_certified_not_started() {
        let mut p = fake();
        p.focus = Focus::Unknown;
        let error = insert(&mut p, Session::X11, "synthetic").unwrap_err();
        assert_eq!(
            error.downcast_ref::<voiceremote_core::InsertionFailure>(),
            Some(&voiceremote_core::InsertionFailure::NotStarted)
        );
        assert!(p.attempts.is_empty());
    }
    #[test]
    fn no_fallback_after_possible_delivery() {
        let mut p = fake();
        p.replies.push_back(Attempt::Failed(Reason::InputFailed));
        p.replies.push_back(Attempt::Inserted);
        assert!(insert(&mut p, Session::Wayland, "synthetic").is_err());
        assert_eq!(p.attempts, [Backend::PortalEis]);
    }
    #[test]
    fn chooses_first_available() {
        let mut p = fake();
        p.replies.extend([
            Attempt::Unavailable(Reason::EisUnavailable),
            Attempt::Inserted,
        ]);
        insert(&mut p, Session::Wayland, "日本語 é 🦀").unwrap();
        assert_eq!(p.attempts, [Backend::PortalEis, Backend::PortalPaste]);
    }
    #[test]
    fn rejects_all_controls_before_any_protocol_call() {
        for c in (0..=0x9f)
            .filter_map(char::from_u32)
            .filter(|c| c.is_control())
            .chain(['\u{2028}', '\u{2029}'])
        {
            let mut p = fake();
            assert!(insert(&mut p, Session::X11, &format!("a{c}b")).is_err());
            assert!(p.attempts.is_empty());
        }
        assert!(validate_text(&"a".repeat(16_385)).is_err());
    }
    #[test]
    fn regression_unknown_focus_refuses_before_backend() {
        let mut p = fake();
        p.focus = Focus::Unknown;
        p.replies.push_back(Attempt::Inserted);
        assert!(insert(&mut p, Session::Wayland, "synthetic").is_err());
        assert!(p.attempts.is_empty());
    }
    #[test]
    fn passwords_denied_and_unknown_is_not_auto_focus() {
        let mut p = fake();
        p.focus = Focus::Password;
        assert!(insert(&mut p, Session::Wayland, "synthetic").is_err());
        assert!(p.attempts.is_empty());
        p.focus = Focus::NotEditable;
        assert!(insert(&mut p, Session::X11, "synthetic").is_err());
        assert!(p.attempts.is_empty());
        assert!(!Focus::Unknown.text_field_focused());
        assert!(!Focus::Password.text_field_focused());
    }
    #[test]
    fn no_text_in_logs_or_errors() {
        use std::io::Write;
        #[derive(Clone)]
        struct Sink(std::sync::Arc<std::sync::Mutex<Vec<u8>>>);
        impl Write for Sink {
            fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
                self.0.lock().unwrap().extend(b);
                Ok(b.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let bytes = std::sync::Arc::new(std::sync::Mutex::new(vec![]));
        let sink = Sink(bytes.clone());
        let subscriber = tracing_subscriber::fmt()
            .without_time()
            .with_ansi(false)
            .with_writer(move || sink.clone())
            .finish();
        tracing::subscriber::with_default(subscriber, || {
            let sentinel = "SYNTHETIC_PRIVACY_SENTINEL";
            let error = insert(&mut fake(), Session::Wayland, sentinel).unwrap_err();
            assert!(!format!("{error:?}").contains(sentinel));
            let mut p = fake();
            p.replies.push_back(Attempt::Failed(Reason::InputFailed));
            assert!(
                !insert(&mut p, Session::X11, sentinel)
                    .unwrap_err()
                    .to_string()
                    .contains(sentinel)
            );
            let mut p = fake();
            p.replies.push_back(Attempt::Inserted);
            insert(&mut p, Session::X11, sentinel).unwrap();
        });
        let logged = String::from_utf8(bytes.lock().unwrap().clone()).unwrap();
        assert!(logged.contains("backend"));
        assert!(!logged.contains("SYNTHETIC_PRIVACY_SENTINEL"));
    }
}
