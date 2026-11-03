// Adapted from anomalyco/hex src/windows/paste.rs (MIT).
// Copyright (c) 2026 Christopher Langton
// See DOCS/licences/hex-MIT.txt for the full permission notice.
use crate::policy::{Event, Key};
use std::mem::size_of;
use voiceremote_core::{Result, ensure};
use windows::Win32::UI::{
    Input::KeyboardAndMouse::*,
    WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId},
};

pub(super) fn require_no_modifiers() -> Result<()> {
    ensure!(
        ![VK_CONTROL, VK_SHIFT, VK_MENU, VK_LWIN, VK_RWIN]
            .iter()
            .any(|k| unsafe { GetAsyncKeyState(i32::from(k.0)) < 0 }),
        "release keyboard modifiers before dictation insertion"
    );
    Ok(())
}
fn native_event(event: Event) -> INPUT {
    let (key, scan, flags) = match event.key {
        Key::Unicode(unit) => (VIRTUAL_KEY(0), unit, KEYEVENTF_UNICODE),
        Key::Control | Key::Paste => {
            let key = if event.key == Key::Control {
                VK_CONTROL
            } else {
                VK_V
            };
            // Chromium derives KeyboardEvent.code from this scan code.
            let scan = unsafe {
                let tid = GetWindowThreadProcessId(GetForegroundWindow(), None);
                MapVirtualKeyExW(
                    u32::from(key.0),
                    MAPVK_VK_TO_VSC,
                    Some(GetKeyboardLayout(tid)),
                ) as u16
            };
            (key, scan, KEYBD_EVENT_FLAGS(0))
        }
    };
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: key,
                wScan: scan,
                dwFlags: if event.up {
                    flags | KEYEVENTF_KEYUP
                } else {
                    flags
                },
                ..Default::default()
            },
        },
    }
}
pub(super) fn send(events: &[Event]) -> Result<()> {
    let inputs: Vec<_> = events.iter().copied().map(native_event).collect();
    let count = unsafe { SendInput(&inputs, size_of::<INPUT>() as i32) };
    if count as usize != inputs.len() {
        // Release only keys we attempted to press, with no new key-down events.
        let cleanup: Vec<_> = events
            .iter()
            .filter(|e| e.up)
            .copied()
            .map(native_event)
            .collect();
        unsafe {
            SendInput(&cleanup, size_of::<INPUT>() as i32);
        }
    }
    ensure!(
        count as usize == inputs.len(),
        "Windows input blocked or partially accepted (possible UIPI/elevated target); delivery uncertain, do not retry automatically"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_mapping_has_no_enter_tab_or_submit_virtual_key() {
        let mut events = crate::policy::paste_events().to_vec();
        events.extend(crate::policy::unicode_events("Synthetic 🦀").unwrap());
        for event in events {
            let input = native_event(event);
            let key = unsafe { input.Anonymous.ki };
            match event.key {
                Key::Unicode(_) => {
                    assert_eq!(key.wVk.0, 0);
                    assert_ne!(key.dwFlags & KEYEVENTF_UNICODE, KEYBD_EVENT_FLAGS(0));
                }
                _ => assert!([VK_CONTROL, VK_V].contains(&key.wVk)),
            }
        }
    }
}
