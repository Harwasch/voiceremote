use crate::{Attempt, Backend, Focus, Platform, Reason, Session, focus, portal::Portal, x11};
use evdev::{AttributeSet, KeyCode, KeyEvent, uinput::VirtualDevice};
use std::{path::PathBuf, process::Stdio, time::Duration};
use tokio::{io::AsyncWriteExt, process::Command, runtime::Runtime, time::timeout};

pub(crate) struct Native {
    path: PathBuf,
    runtime: Option<Runtime>,
    portal: Option<Portal>,
    portal_tried: bool,
    clipboard: Option<x11::Clipboard>,
    uinput: Option<VirtualDevice>,
}
impl Native {
    pub(crate) fn new(path: PathBuf) -> Self {
        Self {
            path,
            runtime: tokio::runtime::Builder::new_multi_thread()
                .worker_threads(1)
                .enable_all()
                .build()
                .ok(),
            portal: None,
            portal_tried: false,
            clipboard: None,
            uinput: None,
        }
    }
    fn open_portal(&mut self) -> bool {
        if self.portal.is_some() {
            return true;
        }
        if self.portal_tried {
            return false;
        }
        self.portal_tried = true;
        let Some(runtime) = &self.runtime else {
            return false;
        };
        self.portal = runtime.block_on(async {
            timeout(Duration::from_secs(120), Portal::open(&self.path))
                .await
                .ok()
                .and_then(Result::ok)
        });
        self.portal.is_some()
    }
    fn open_clipboard(&mut self) -> bool {
        if self.clipboard.as_ref().is_some_and(|c| !c.is_alive()) {
            self.clipboard = None;
        }
        if self.clipboard.is_none() {
            self.clipboard = x11::Clipboard::new().ok();
        }
        self.clipboard.is_some()
    }
    pub(crate) fn reported_focus(&mut self) -> Focus {
        self.focus()
    }
    fn restore(
        &self,
        portal_id: Option<u64>,
        x11_id: Option<u64>,
        sent: bool,
    ) -> Result<(), Reason> {
        if let Some(id) = portal_id {
            self.runtime
                .as_ref()
                .unwrap()
                .block_on(self.portal.as_ref().unwrap().finish_clipboard(id, sent))
                .map_err(|_| Reason::ClipboardRestoreFailed)?;
            Ok(())
        } else {
            self.clipboard
                .as_ref()
                .unwrap()
                .finish(x11_id.unwrap(), sent)
        }
    }
    fn paste_with(&mut self, backend: Backend, text: &str, terminal: bool) -> Attempt {
        let keyboard = if backend == Backend::XTestPaste {
            match x11::Keyboard::prepare(None) {
                Ok(k) => Some(k),
                Err(_) => return Attempt::Unavailable(Reason::ModifiersHeld),
            }
        } else {
            None
        };
        if backend == Backend::PortalPaste && !self.portal.as_ref().unwrap().can_paste(terminal) {
            return Attempt::Unavailable(Reason::UnsupportedLayout);
        }
        if backend == Backend::Uinput {
            // A physical KEY_V is safe only if a live layout proves it is V.
            // No usable map/group information is a refusal, never a US-layout guess.
            if !x11::physical_paste_layout().is_some_and(uinput_layout_safe) {
                return Attempt::Unavailable(Reason::UnsupportedLayout);
            }
            if self.uinput.is_none() {
                let mut keys = AttributeSet::new();
                for key in [
                    KeyCode::KEY_LEFTCTRL,
                    KeyCode::KEY_LEFTSHIFT,
                    KeyCode::KEY_V,
                ] {
                    keys.insert(key);
                }
                self.uinput = VirtualDevice::builder()
                    .and_then(|b| b.name(&"VoiceRemote dictation paste").with_keys(&keys))
                    .and_then(|b| b.build())
                    .ok();
                if self.uinput.is_none() {
                    return Attempt::Unavailable(Reason::PermissionDenied);
                }
                std::thread::sleep(Duration::from_millis(300));
            }
        }
        let portal_id = if backend != Backend::XTestPaste {
            match (&self.runtime, &self.portal) {
                (Some(runtime), Some(portal)) => {
                    let saved = runtime.block_on(async {
                        timeout(Duration::from_secs(2), portal.prepare_clipboard())
                            .await
                            .ok()
                            .and_then(Result::ok)
                    });
                    if let Some(saved) = saved {
                        match runtime.block_on(portal.install_clipboard(text, saved)) {
                            Ok(id) => Some(id),
                            Err(_) => return Attempt::Failed(Reason::ClipboardRestoreFailed),
                        }
                    } else {
                        None
                    }
                }
                _ => None,
            }
        } else {
            None
        };
        let x11_id = if portal_id.is_none() {
            if !self.open_clipboard() {
                return Attempt::Unavailable(Reason::ClipboardUnavailable);
            }
            match self.clipboard.as_ref().unwrap().install(text) {
                Ok(id) => Some(id),
                Err(Reason::ClipboardRestoreFailed) => {
                    return Attempt::Failed(Reason::ClipboardRestoreFailed);
                }
                Err(reason) => return Attempt::Unavailable(reason),
            }
        } else {
            None
        };
        let focus = self.focus();
        if !focus.text_field_focused() || (focus == Focus::Terminal) != terminal {
            return match self.restore(portal_id, x11_id, false) {
                Ok(()) => Attempt::Failed(Reason::FocusChanged),
                Err(reason) => Attempt::Failed(reason),
            };
        }
        // Reads may come from a manager. Keep the selection for the full bounded
        // window, then restore conditionally; delivery still remains unconfirmed.
        let success = match backend {
            Backend::PortalPaste => self
                .runtime
                .as_ref()
                .unwrap()
                .block_on(self.portal.as_mut().unwrap().paste(terminal))
                .is_ok(),
            Backend::XTestPaste => keyboard.unwrap().send(true, terminal).is_ok(),
            Backend::Uinput => {
                let device = self.uinput.as_mut().unwrap();
                let mut keys = vec![KeyCode::KEY_LEFTCTRL];
                if terminal {
                    keys.push(KeyCode::KEY_LEFTSHIFT);
                }
                keys.push(KeyCode::KEY_V);
                let down: Vec<_> = keys.iter().map(|k| *KeyEvent::new(*k, 1)).collect();
                let up: Vec<_> = keys.iter().rev().map(|k| *KeyEvent::new(*k, 0)).collect();
                let press = device.emit(&down);
                let release = device.emit(&up);
                press.and(release).is_ok()
            }
            _ => unreachable!(),
        };
        if let Err(reason) = self.restore(portal_id, x11_id, true) {
            return Attempt::Failed(reason);
        }
        Attempt::Failed(if success {
            Reason::DeliveryUnconfirmed
        } else {
            Reason::InputFailed
        })
    }
}
impl Platform for Native {
    fn focus(&mut self) -> Focus {
        self.runtime
            .as_ref()
            .map(|r| r.block_on(focus::report(Session::detect())))
            .unwrap_or(Focus::Unknown)
    }
    fn attempt(&mut self, backend: Backend, text: &str) -> Attempt {
        let focus = self.focus();
        if !focus.text_field_focused() {
            return Attempt::Failed(Reason::FocusUnknown);
        }
        let terminal = focus == Focus::Terminal;
        match backend {
            Backend::PortalEis => {
                if !self.open_portal() {
                    return Attempt::Unavailable(Reason::PortalUnavailable);
                }
                if !self.focus().text_field_focused() {
                    return Attempt::Failed(Reason::FocusChanged);
                }
                let runtime = self.runtime.as_ref().unwrap();
                let portal = self.portal.as_mut().unwrap();
                runtime.block_on(async {
                    let eis = match timeout(Duration::from_secs(2), portal.eis()).await {
                        Ok(Ok(eis)) => eis,
                        _ => return Attempt::Unavailable(Reason::EisUnavailable),
                    };
                    if eis.refresh().is_err() {
                        return Attempt::Unavailable(Reason::EisUnavailable);
                    }
                    if !eis.supports_text() {
                        return Attempt::Unavailable(Reason::EisUnavailable);
                    }
                    match timeout(Duration::from_secs(2), eis.send(text)).await {
                        Ok(Ok(())) => Attempt::Inserted,
                        _ => Attempt::Failed(Reason::InputFailed),
                    }
                })
            }
            Backend::PortalPaste => {
                if !self.open_portal() {
                    return Attempt::Unavailable(Reason::PortalUnavailable);
                }
                self.paste_with(backend, text, terminal)
            }
            Backend::XTestPaste | Backend::Uinput => self.paste_with(backend, text, terminal),
            Backend::XTestType => {
                let keyboard = match x11::Keyboard::prepare(Some(text)) {
                    Ok(k) => k,
                    Err(_) => return Attempt::Unavailable(Reason::UnsupportedLayout),
                };
                if !self.focus().text_field_focused() {
                    return Attempt::Failed(Reason::FocusChanged);
                }
                if keyboard.send(false, false).is_ok() {
                    Attempt::Inserted
                } else {
                    Attempt::Failed(Reason::InputFailed)
                }
            }
            Backend::Wtype | Backend::Dotool => {
                if backend == Backend::Wtype
                    && std::env::var("XDG_CURRENT_DESKTOP")
                        .unwrap_or_default()
                        .split(':')
                        .any(|s| s.eq_ignore_ascii_case("gnome"))
                {
                    return Attempt::Unavailable(Reason::HelperUnavailable);
                }
                let Some(runtime) = &self.runtime else {
                    return Attempt::Unavailable(Reason::HelperUnavailable);
                };
                runtime.block_on(helper(backend, text))
            }
        }
    }
}

// Copyright (c) 2025 CJ Pais
// Adapted from Handy's dotool text protocol (MIT); DOCS/licences/Handy-MIT.txt.
fn helper_input(backend: Backend, text: &str) -> Vec<u8> {
    match backend {
        Backend::Dotool => format!("type {text}\n").into_bytes(),
        _ => text.as_bytes().to_vec(),
    }
}
fn uinput_layout_safe(symbol_on_v: u32) -> bool {
    symbol_on_v == b'v' as u32
}

async fn helper(backend: Backend, text: &str) -> Attempt {
    if crate::validate_text(text).is_err() {
        return Attempt::Failed(Reason::InputFailed);
    }
    let (program, args): (&str, &[&str]) = if backend == Backend::Wtype {
        ("wtype", &["-"])
    } else {
        ("dotool", &[])
    };
    let Some(program) = resolve_helper(program) else {
        return Attempt::Unavailable(Reason::HelperUnavailable);
    };
    helper_program(backend, text, program.as_os_str(), args).await
}
fn resolve_helper(program: &str) -> Option<PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    if program.is_empty() || program.contains('/') || program.contains("..") {
        return None;
    }
    ["/usr/bin", "/bin", "/usr/local/bin"]
        .iter()
        .find_map(|dir| {
            let path = std::fs::canonicalize(std::path::Path::new(dir).join(program)).ok()?;
            let metadata = std::fs::metadata(&path).ok()?;
            (metadata.is_file() && metadata.permissions().mode() & 0o111 != 0).then_some(path)
        })
}

async fn helper_program(
    backend: Backend,
    text: &str,
    program: &std::ffi::OsStr,
    args: &[&str],
) -> Attempt {
    if crate::validate_text(text).is_err() {
        return Attempt::Failed(Reason::InputFailed);
    }
    let mut child = match Command::new(program)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
    {
        Ok(child) => child,
        Err(_) => return Attempt::Unavailable(Reason::HelperUnavailable),
    };
    let input = helper_input(backend, text);
    let result = timeout(Duration::from_secs(5), async {
        let mut stdin = child.stdin.take().unwrap();
        stdin.write_all(&input).await?;
        drop(stdin);
        child.wait().await
    })
    .await;
    match result {
        Ok(Ok(status)) if status.success() => Attempt::Inserted,
        _ => Attempt::Failed(Reason::InputFailed),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn regression_helpers_never_use_path_search() {
        assert!(resolve_helper("sh").unwrap().is_absolute());
        assert!(resolve_helper("../untrusted").is_none());
    }
    #[test]
    fn regression_uinput_refuses_dvorak_physical_v() {
        assert!(!uinput_layout_safe(b'k' as u32));
        assert!(uinput_layout_safe(b'v' as u32));
    }
    #[test]
    fn helper_protocol_sends_stdin_redacts_output_and_propagates_failure() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("helper");
        std::fs::write(&path, "#!/bin/sh\n[ \"$#\" -eq 1 ] || exit 9\n[ \"$1\" = '-' ] || exit 9\nread -r line\n[ \"$line\" = 'SYNTHETIC_HELPER_SENTINEL' ] || exit 9\nprintf '%s' \"$line\" >&2\nexit 0\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        // read sees EOF without newline but still sets the variable; literal data
        // never enters arguments, a shell command, or inherited stderr.
        assert!(matches!(
            runtime.block_on(helper_program(
                Backend::Wtype,
                "SYNTHETIC_HELPER_SENTINEL",
                path.as_os_str(),
                &["-"]
            )),
            Attempt::Inserted
        ));
        std::fs::write(&path, "#!/bin/sh\ncat >/dev/null\nexit 7\n").unwrap();
        assert!(matches!(
            runtime.block_on(helper_program(
                Backend::Dotool,
                "synthetic",
                path.as_os_str(),
                &[]
            )),
            Attempt::Failed(Reason::InputFailed)
        ));
        assert!(matches!(
            runtime.block_on(helper_program(
                Backend::Dotool,
                "synthetic",
                temp.path().join("absent").as_os_str(),
                &[]
            )),
            Attempt::Unavailable(Reason::HelperUnavailable)
        ));
    }
    #[test]
    fn helper_data_is_literal_stdin_never_argv_or_commands() {
        let text = "synthetic -- key Return $(fixture) ";
        assert_eq!(helper_input(Backend::Wtype, text), text.as_bytes());
        assert_eq!(
            helper_input(Backend::Dotool, text),
            format!("type {text}\n").as_bytes()
        );
        assert!(crate::validate_text("fixture\nkey Return").is_err());
    }
}
