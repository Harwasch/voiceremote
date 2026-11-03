// Portions adapted from anomalyco/hex src/windows/paste.rs (MIT).
// Copyright (c) 2026 Christopher Langton
// See DOCS/licences/hex-MIT.txt and DOCS/licences/README.md for provenance.
//! OS-independent policy; the native adapter uses these exact event plans.
use voiceremote_core::{Result, ensure};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Key {
    Control,
    Paste,
    Unicode(u16),
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Event {
    pub key: Key,
    pub up: bool,
}

pub fn validate_text(text: &str) -> Result<()> {
    ensure!(
        text.chars().count() <= 16_384,
        "dictation exceeds text limit"
    );
    ensure!(
        !text
            .chars()
            .any(|c| c.is_control() || matches!(c, '\u{2028}' | '\u{2029}')),
        "dictation contains a forbidden control or separator"
    );
    Ok(())
}

pub fn paste_events() -> [Event; 4] {
    [
        Event {
            key: Key::Control,
            up: false,
        },
        Event {
            key: Key::Paste,
            up: false,
        },
        Event {
            key: Key::Paste,
            up: true,
        },
        Event {
            key: Key::Control,
            up: true,
        },
    ]
}

pub fn unicode_events(text: &str) -> Result<Vec<Event>> {
    validate_text(text)?;
    Ok(text
        .encode_utf16()
        .flat_map(|unit| {
            [
                Event {
                    key: Key::Unicode(unit),
                    up: false,
                },
                Event {
                    key: Key::Unicode(unit),
                    up: true,
                },
            ]
        })
        .collect())
}

/// All properties are metadata; unknown password/read-only states fail closed.
#[derive(Clone, Copy, Debug, Default)]
pub struct FocusEvidence {
    pub focused: bool,
    pub enabled: bool,
    pub password: Option<bool>,
    pub editable: Option<bool>,
}
pub fn editable_focus(e: FocusEvidence) -> bool {
    e.focused && e.enabled && e.password == Some(false) && e.editable == Some(true)
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FocusSnapshot {
    pub text_field_focused: bool,
    pub last_activity_at: u64,
}
pub fn last_activity_at(now_ms: u64, tick_ms: u32, last_input_ms: u32) -> u64 {
    now_ms.saturating_sub(u64::from(tick_ms.wrapping_sub(last_input_ms)))
}
pub fn may_restore(published: u32, current: u32, owner_is_ours: bool, rendered: bool) -> bool {
    // Rendering/synthesizing formats can itself advance the sequence. The
    // transaction has a unique HWND: a new user copy changes clipboard owner.
    owner_is_ours && (published == current || rendered)
}

/// Only a failure before a paste chord is attempted permits Unicode fallback.
/// A missing read receipt after a chord is ambiguous; retry could duplicate text.
pub enum PasteAttempt {
    Unavailable,
    Finished(Result<()>),
}
pub trait Backend {
    fn require_target(&mut self) -> Result<()>;
    fn paste(&mut self, text: &str) -> PasteAttempt;
    fn unicode(&mut self, events: &[Event]) -> Result<()>;
}
pub fn insert(backend: &mut impl Backend, text: &str) -> Result<()> {
    validate_text(text)?;
    if text.is_empty() {
        return Ok(());
    }
    backend.require_target()?;
    match backend.paste(text) {
        PasteAttempt::Finished(result) => result,
        PasteAttempt::Unavailable => {
            backend.require_target()?;
            backend.unicode(&unicode_events(text)?)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use voiceremote_core::bail;

    #[test]
    fn every_control_and_line_separator_is_rejected_before_any_os_access() {
        for c in (0..=0x9f)
            .filter_map(char::from_u32)
            .filter(|c| c.is_control())
            .chain(['\u{2028}', '\u{2029}'])
        {
            let mut b = Fake::default();
            assert!(insert(&mut b, &format!("test{c}")).is_err());
            assert!(b.calls.is_empty());
        }
        assert!(validate_text(&"x".repeat(16_385)).is_err());
    }
    #[test]
    fn plans_can_only_paste_or_insert_literal_unicode_and_never_submit() {
        assert_eq!(
            paste_events().map(|e| (e.key, e.up)),
            [
                (Key::Control, false),
                (Key::Paste, false),
                (Key::Paste, true),
                (Key::Control, true),
            ]
        );
        let text = "Synthetic café 漢字 🦀";
        let events = unicode_events(text).unwrap();
        let mut units = Vec::new();
        for pair in events.as_chunks::<2>().0 {
            let Key::Unicode(unit) = pair[0].key else {
                panic!("virtual key in Unicode plan")
            };
            assert!(![0x0d, 0x09, 0x0a].contains(&unit));
            assert_eq!(
                pair[1],
                Event {
                    key: pair[0].key,
                    up: true
                }
            );
            assert!(!pair[0].up);
            units.push(unit);
        }
        assert_eq!(String::from_utf16(&units).unwrap(), text);
    }
    #[test]
    fn passwords_unknown_metadata_disabled_and_readonly_are_not_focused() {
        let good = FocusEvidence {
            focused: true,
            enabled: true,
            password: Some(false),
            editable: Some(true),
        };
        assert!(editable_focus(good));
        for bad in [
            FocusEvidence {
                password: Some(true),
                ..good
            },
            FocusEvidence {
                password: None,
                ..good
            },
            FocusEvidence {
                editable: None,
                ..good
            },
            FocusEvidence {
                editable: Some(false),
                ..good
            },
            FocusEvidence {
                enabled: false,
                ..good
            },
            FocusEvidence {
                focused: false,
                ..good
            },
        ] {
            assert!(!editable_focus(bad));
        }
    }
    #[test]
    fn activity_uses_input_time_not_poll_time_and_handles_tick_wrap() {
        assert_eq!(last_activity_at(100_000, 5_000, 1_000), 96_000);
        assert_eq!(last_activity_at(100_000, 5, u32::MAX - 4), 99_990);
        assert_eq!(last_activity_at(5, 100, 0), 0);
    }
    #[test]
    fn restoration_never_overwrites_a_new_user_copy() {
        assert!(may_restore(10, 10, true, false));
        assert!(!may_restore(10, 11, true, false));
        assert!(may_restore(10, 11, true, true));
        assert!(!may_restore(10, 10, false, false));
        assert!(!may_restore(10, 11, false, true));
    }
    #[derive(Default)]
    struct Fake {
        calls: Vec<&'static str>,
        unavailable: bool,
        paste_error: bool,
        denied: bool,
    }
    impl Backend for Fake {
        fn require_target(&mut self) -> Result<()> {
            self.calls.push("target");
            if self.denied {
                bail!("password, missing focus or UIPI");
            }
            Ok(())
        }
        fn paste(&mut self, _: &str) -> PasteAttempt {
            self.calls.push("paste");
            if self.unavailable {
                PasteAttempt::Unavailable
            } else if self.paste_error {
                PasteAttempt::Finished(Err(voiceremote_core::anyhow!(
                    "ambiguous delivery or restore failed"
                )))
            } else {
                PasteAttempt::Finished(Ok(()))
            }
        }
        fn unicode(&mut self, _: &[Event]) -> Result<()> {
            self.calls.push("unicode");
            Ok(())
        }
    }
    #[test]
    fn prefers_paste_and_falls_back_only_before_the_chord() {
        let mut b = Fake::default();
        insert(&mut b, "synthetic").unwrap();
        assert_eq!(b.calls, ["target", "paste"]);
        let mut b = Fake {
            unavailable: true,
            ..Fake::default()
        };
        insert(&mut b, "synthetic").unwrap();
        assert_eq!(b.calls, ["target", "paste", "target", "unicode"]);
        let mut b = Fake {
            paste_error: true,
            ..Fake::default()
        };
        assert!(insert(&mut b, "synthetic").is_err());
        assert_eq!(b.calls, ["target", "paste"]);
    }
    #[test]
    fn denied_target_and_empty_text_never_touch_clipboard_or_keyboard() {
        let mut b = Fake {
            denied: true,
            ..Fake::default()
        };
        assert!(insert(&mut b, "synthetic").is_err());
        assert_eq!(b.calls, ["target"]);
        b.calls.clear();
        insert(&mut b, "").unwrap();
        assert!(b.calls.is_empty());
    }
}
