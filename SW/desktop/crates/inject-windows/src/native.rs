//! The worker owns its COM apartment and message-only clipboard window.
//! No overlay or visible window is created by the injector.
use crate::policy::{self, Backend, Event, FocusSnapshot, PasteAttempt};
use std::{
    sync::{Mutex, OnceLock, mpsc},
    thread,
    time::Duration,
};
use voiceremote_core::{Result, TextInjector, anyhow};

mod clipboard;
mod focus;
mod input;

static INSERTION: Mutex<()> = Mutex::new(());

#[derive(Default)]
pub struct WindowsInjector;
impl TextInjector for WindowsInjector {
    fn insert_text(&mut self, text: &str) -> Result<()> {
        // Validate before copying into the worker or consulting any OS API.
        policy::validate_text(text)?;
        if text.is_empty() {
            return Ok(());
        }
        let text = text.to_owned();
        let result = thread::spawn(move || {
            let _lock = INSERTION
                .lock()
                .map_err(|_| anyhow!("Windows injector lock poisoned"))?;
            let mut backend = Native {
                target: focus::Target::capture()?,
            };
            policy::insert(&mut backend, &text)
        })
        .join()
        .map_err(|_| anyhow!("Windows injector worker failed"))?;
        safe_diagnostic(result)
    }
}
fn safe_diagnostic(result: Result<()>) -> Result<()> {
    result.map_err(|error| {
        // COM providers control error descriptions. Never expose them through
        // the app's diagnostics: an arbitrary description could contain text.
        if let Some(os) = error.downcast_ref::<windows::core::Error>() {
            anyhow!("Windows API failed (HRESULT=0x{:08x}); target unavailable (possible UIA/UIPI restriction)", os.code().0 as u32)
        } else {
            error // Our remaining errors are fixed, content-free diagnostics.
        }
    })
}
struct Native {
    target: focus::Target,
}
impl Backend for Native {
    fn require_target(&mut self) -> Result<()> {
        self.target.require_unchanged()?;
        input::require_no_modifiers()
    }
    fn paste(&mut self, text: &str) -> PasteAttempt {
        clipboard::paste(&self.target, text)
    }
    fn unicode(&mut self, events: &[Event]) -> Result<()> {
        self.require_target()?;
        input::send(events)
    }
}

/// Only the boolean and input timestamp leave this module. UIA failures mean
/// not focused; they never trigger a field-value or window-title read.
pub fn focus_snapshot() -> FocusSnapshot {
    // A provider can hang in a COM call. One bounded, detached worker prevents
    // a stuck provider from blocking session shutdown or accumulating threads.
    static SAMPLER: OnceLock<mpsc::SyncSender<mpsc::Sender<FocusSnapshot>>> = OnceLock::new();
    let sampler = SAMPLER.get_or_init(|| {
        let (send, receive) = mpsc::sync_channel::<mpsc::Sender<FocusSnapshot>>(1);
        thread::spawn(move || {
            while let Ok(reply) = receive.recv() {
                let snapshot = FocusSnapshot {
                    text_field_focused: focus::Target::capture().is_ok(),
                    last_activity_at: focus::activity_timestamp(),
                };
                let _ = reply.send(snapshot);
            }
        });
        send
    });
    let (reply, receive) = mpsc::channel();
    if sampler.try_send(reply).is_err() {
        return FocusSnapshot::default();
    }
    receive
        .recv_timeout(Duration::from_millis(500))
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn provider_error_descriptions_never_reach_diagnostics() {
        let error = windows::core::Error::new(
            windows::core::HRESULT(0x80004005u32 as i32),
            "Synthetic private field sentinel",
        );
        let error = safe_diagnostic(Err(error.into())).unwrap_err().to_string();
        assert!(error.contains("0x80004005"));
        assert!(!error.contains("sentinel"));
    }
}
