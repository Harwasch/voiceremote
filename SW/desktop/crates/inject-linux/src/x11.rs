//! XTest input and an ICCCM selection owner, using pure Rust x11rb.
//! Clipboard preservation/conditional restoration follows Hex's Linux design.
// Copyright (c) 2026 Christopher Langton
// Adapted from https://github.com/anomalyco/hex (MIT); see DOCS/licences/hex-MIT.txt.
use crate::{Reason, validate_text};
use anyhow::{Result, ensure};
use std::{
    collections::BTreeMap,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};
use x11rb::{
    CURRENT_TIME, NONE,
    connection::{Connection, RequestConnection},
    protocol::{
        Event,
        xkb::{ConnectionExt as _, ID},
        xproto::*,
        xtest::ConnectionExt as _,
    },
    rust_connection::RustConnection,
    wrapper::ConnectionExt as _,
};
const CAP: usize = 32 * 1024 * 1024;
const DEADLINE: Duration = Duration::from_secs(2);

pub(crate) fn active_window() -> Option<u32> {
    let (c, screen) = x11rb::connect(None).ok()?;
    let atom = c
        .intern_atom(false, b"_NET_ACTIVE_WINDOW")
        .ok()?
        .reply()
        .ok()?
        .atom;
    let root = c.setup().roots[screen].root;
    let active = c
        .get_property(false, root, atom, AtomEnum::WINDOW, 0, 1)
        .ok()
        .and_then(|r| r.reply().ok())
        .and_then(|r| r.value32().and_then(|mut v| v.next()));
    active.filter(|w| *w > 1).or_else(|| {
        c.get_input_focus()
            .ok()?
            .reply()
            .ok()
            .map(|r| r.focus)
            .filter(|w| *w > 1)
    })
}

pub(crate) fn window_pid(window: u32) -> Option<u32> {
    let (c, _) = x11rb::connect(None).ok()?;
    let atom = c
        .intern_atom(false, b"_NET_WM_PID")
        .ok()?
        .reply()
        .ok()?
        .atom;
    c.get_property(false, window, atom, AtomEnum::CARDINAL, 0, 1)
        .ok()?
        .reply()
        .ok()?
        .value32()?
        .next()
}

pub(crate) fn physical_paste_layout() -> Option<u32> {
    let (c, _) = x11rb::connect(None).ok()?;
    c.xkb_use_extension(1, 0).ok()?.reply().ok()?;
    let state = c
        .xkb_get_state(ID::USE_CORE_KBD.into())
        .ok()?
        .reply()
        .ok()?;
    if u8::from(state.group) != 0 {
        return None;
    }
    for (code, expected) in [(37, 0xffe3), (50, 0xffe1)] {
        if c.get_keyboard_mapping(code, 1)
            .ok()?
            .reply()
            .ok()?
            .keysyms
            .first()
            != Some(&expected)
        {
            return None;
        }
    }
    c.get_keyboard_mapping(55, 1)
        .ok()?
        .reply()
        .ok()?
        .keysyms
        .first()
        .copied()
}
pub(crate) fn terminal_window(window: u32) -> bool {
    let result = (|| -> Option<bool> {
        let (c, _) = x11rb::connect(None).ok()?;
        let data = c
            .get_property(false, window, AtomEnum::WM_CLASS, AtomEnum::STRING, 0, 1024)
            .ok()?
            .reply()
            .ok()?;
        Some(
            data.value
                .split(|b| *b == 0)
                .filter_map(|s| std::str::from_utf8(s).ok())
                .any(|class| {
                    matches!(
                        class.to_ascii_lowercase().as_str(),
                        "xterm"
                            | "uxterm"
                            | "gnome-terminal-server"
                            | "org.gnome.terminal"
                            | "kgx"
                            | "org.gnome.console"
                            | "alacritty"
                            | "kitty"
                            | "wezterm"
                            | "konsole"
                            | "foot"
                            | "terminator"
                    )
                }),
        )
    })();
    result.unwrap_or(false)
}

pub(crate) struct Keyboard {
    c: RustConnection,
    target: u32,
    plan: Vec<(u8, bool)>,
    shift: u8,
    ctrl: u8,
    ignored_locks: u16,
}
impl Keyboard {
    pub(crate) fn prepare(text: Option<&str>) -> Result<Self> {
        let (c, _) = x11rb::connect(None)?;
        c.xtest_get_version(2, 2)?.reply()?;
        ensure!(
            c.xkb_use_extension(1, 0)?.reply()?.supported,
            "XKB unavailable"
        );
        let target = c.get_input_focus()?.reply()?.focus;
        ensure!(target > 1, "no focused window");
        let map = c
            .get_keyboard_mapping(
                c.setup().min_keycode,
                c.setup().max_keycode - c.setup().min_keycode + 1,
            )?
            .reply()?;
        let width = map.keysyms_per_keycode as usize;
        let modifiers = c.get_modifier_mapping()?.reply()?;
        let mut ignored_locks = 0u16;
        let mut caps_mask = 0u16;
        let per_modifier = modifiers.keycodes.len() / 8;
        for (bit, keys) in modifiers.keycodes.chunks(per_modifier).enumerate() {
            for key in keys.iter().filter(|k| **k >= c.setup().min_keycode) {
                let start = (*key - c.setup().min_keycode) as usize * width;
                if let Some(row) = map.keysyms.get(start..start + width) {
                    if row.iter().any(|s| matches!(*s, 0xffe5 | 0xff7f)) {
                        ignored_locks |= 1 << bit;
                    }
                    if row.contains(&0xffe5) {
                        caps_mask |= 1 << bit;
                    }
                }
            }
        }
        let state = c.xkb_get_state(ID::USE_CORE_KBD.into())?.reply()?;
        let caps = u16::from(state.locked_mods) & caps_mask != 0;
        let lookup = |sym: u32| -> Option<(u8, bool)> {
            map.keysyms.chunks(width).enumerate().find_map(|(i, row)| {
                row.iter()
                    .take(2)
                    .position(|s| *s == sym)
                    .map(|level| (c.setup().min_keycode + i as u8, level == 1))
            })
        };
        let (shift, _) = lookup(0xffe1).ok_or_else(|| anyhow::anyhow!("no shift"))?;
        let (ctrl, _) = lookup(0xffe3).ok_or_else(|| anyhow::anyhow!("no control"))?;
        let plan = if let Some(text) = text {
            validate_text(text)?;
            text.chars()
                .map(|ch| {
                    let sym = if ch as u32 <= 0xff {
                        ch as u32
                    } else {
                        0x01000000 | ch as u32
                    };
                    let found = lookup(sym)
                        .map(|(key, shift)| (key, shift ^ (caps && ch.is_ascii_alphabetic())));
                    if caps && ch.is_alphabetic() && !ch.is_ascii() {
                        anyhow::bail!("non-ASCII CapsLock typing unsupported");
                    }
                    found.ok_or_else(|| {
                        anyhow::anyhow!("character unavailable in current keyboard group")
                    })
                })
                .collect::<Result<Vec<_>>>()?
        } else {
            vec![lookup(b'v' as u32).ok_or_else(|| anyhow::anyhow!("no v"))?]
        };
        // Never infer a submit/navigation key from the layout. Even a malicious
        // keyboard map must not route a printable symbol to a Return/Tab key.
        for key in plan.iter().map(|(key, _)| *key).chain([ctrl, shift]) {
            ensure!(![23, 36, 104].contains(&key), "forbidden physical key");
            let row = &map.keysyms[(key - c.setup().min_keycode) as usize * width..][..width];
            ensure!(safe_keysyms(row), "forbidden key mapping");
        }
        let mut keyboard = Self {
            c,
            target,
            plan,
            shift,
            ctrl,
            ignored_locks,
        };
        keyboard.check_ready()?;
        Ok(keyboard)
    }
    fn check_ready(&mut self) -> Result<()> {
        ensure!(
            self.c.get_input_focus()?.reply()?.focus == self.target,
            "focus changed"
        );
        let state = self.c.xkb_get_state(ID::USE_CORE_KBD.into())?.reply()?;
        ensure!(
            modifier_state_allowed(
                u16::from(state.mods),
                u8::from(state.group),
                self.ignored_locks
            ),
            "keyboard group or modifiers unsupported"
        );
        let pointer = self
            .c
            .query_pointer(self.c.setup().roots[0].root)?
            .reply()?;
        ensure!(
            modifier_state_allowed(u16::from(pointer.mask) & 0xff, 0, self.ignored_locks),
            "modifiers held"
        );
        Ok(())
    }
    fn key(&self, key: u8, down: bool) -> Result<()> {
        self.c
            .xtest_fake_input(
                if down {
                    KEY_PRESS_EVENT
                } else {
                    KEY_RELEASE_EVENT
                },
                key,
                CURRENT_TIME,
                NONE,
                0,
                0,
                0,
            )?
            .check()?;
        Ok(())
    }
    pub(crate) fn send(mut self, paste: bool, terminal: bool) -> Result<()> {
        self.check_ready()?;
        // Finally blocks release synthetic modifiers even on a failed X request.
        let result = (|| {
            if paste {
                self.key(self.ctrl, true)?;
                if terminal {
                    self.key(self.shift, true)?;
                }
            }
            for &(key, shift) in &self.plan {
                if shift && !paste {
                    self.key(self.shift, true)?;
                }
                let pressed = self.key(key, true);
                let released = self.key(key, false);
                let result = pressed.and(released);
                if shift && !paste {
                    self.key(self.shift, false)?;
                }
                result?;
            }
            Ok(())
        })();
        if paste {
            let shift_release = if terminal {
                self.key(self.shift, false)
            } else {
                Ok(())
            };
            let release = self.key(self.ctrl, false);
            result.and(shift_release).and(release)?;
        } else {
            result?;
        }
        self.c.get_input_focus()?.reply()?; // Round trip, surface protocol errors.
        Ok(())
    }
}

fn request_result(result: Result<()>) -> Result<()> {
    match result {
        Err(error) if error.downcast_ref::<x11rb::errors::ReplyError>().is_some_and(|e| matches!(e, x11rb::errors::ReplyError::X11Error(e) if e.error_kind == x11rb::protocol::ErrorKind::Window)) => Ok(()),
        result => result,
    }
}

fn modifier_state_allowed(mods: u16, group: u8, lock_mask: u16) -> bool {
    mods & !lock_mask == 0 && group == 0
}

fn safe_keysyms(row: &[u32]) -> bool {
    !row.iter().any(|sym| {
        matches!(
            *sym,
            0xff0d
                | 0xff09
                | 0xfe20
                | 0xff8d
                | 0xff0a
                | 0xfe34
                | 0xff89
                | 0xfd1e
                | 0x1008ff7b
                | 0xff7e
                | 0xff15
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn regression_dying_requestor_is_not_owner_failure() {
        let error = x11rb::errors::ReplyError::X11Error(x11rb::x11_utils::X11Error {
            error_kind: x11rb::protocol::ErrorKind::Window,
            error_code: 3,
            sequence: 1,
            bad_value: 99,
            minor_opcode: 0,
            major_opcode: 18,
            extension_name: None,
            request_name: None,
        });
        assert!(request_result(Err(error.into())).is_ok());
        assert!(request_result(Err(anyhow::anyhow!("connection lost"))).is_err());
    }
    #[test]
    fn regression_lock_modifiers_do_not_disable_injection() {
        assert!(modifier_state_allowed(2 | 16, 0, 2 | 16));
        assert!(!modifier_state_allowed(4, 0, 2 | 16));
        assert!(!modifier_state_allowed(8, 0, 2 | 16));
    }
    #[test]
    fn layout_cannot_hide_submit_or_tab_on_other_levels() {
        for sym in [
            0xff0d, 0xff09, 0xfe20, 0xff8d, 0xff0a, 0xfe34, 0xff89, 0xfd1e, 0x1008ff7b,
        ] {
            assert!(!safe_keysyms(&[b'a' as u32, b'A' as u32, sym]));
        }
        assert!(safe_keysyms(&[b'v' as u32, b'V' as u32, 0]));
        assert!(safe_keysyms(&[0xffe1, 0xffe3]));
    }
}

#[derive(Clone)]
struct Value {
    kind: u32,
    format: u8,
    bytes: Vec<u8>,
}
type Formats = BTreeMap<u32, Value>;
struct Atoms {
    clipboard: u32,
    targets: u32,
    utf8: u32,
    plain: u32,
    property: u32,
    incr: u32,
    multiple: u32,
    timestamp: u32,
    save: u32,
}
impl Atoms {
    fn new(c: &RustConnection) -> Result<Self> {
        let atom = |n: &[u8]| -> Result<u32> { Ok(c.intern_atom(false, n)?.reply()?.atom) };
        Ok(Self {
            clipboard: atom(b"CLIPBOARD")?,
            targets: atom(b"TARGETS")?,
            utf8: atom(b"UTF8_STRING")?,
            plain: atom(b"text/plain;charset=utf-8")?,
            property: atom(b"VOICEREMOTE_SELECTION")?,
            incr: atom(b"INCR")?,
            multiple: atom(b"MULTIPLE")?,
            timestamp: atom(b"TIMESTAMP")?,
            save: atom(b"SAVE_TARGETS")?,
        })
    }
}
enum Command {
    Install(String, mpsc::SyncSender<std::result::Result<u64, Reason>>),
    Restore(u64, mpsc::SyncSender<Result<()>>),
    Stop,
}
pub(crate) struct Clipboard {
    send: mpsc::Sender<Command>,
    alive: Arc<AtomicBool>,
}
impl Clipboard {
    pub(crate) fn new() -> Result<Self> {
        let (c, screen) = x11rb::connect(None)?;
        let window = c.generate_id()?;
        c.create_window(
            0,
            window,
            c.setup().roots[screen].root,
            0,
            0,
            1,
            1,
            0,
            WindowClass::INPUT_OUTPUT,
            0,
            &CreateWindowAux::new().event_mask(EventMask::PROPERTY_CHANGE),
        )?
        .check()?;
        let a = Atoms::new(&c)?;
        let (send, receive) = mpsc::channel();
        let alive = Arc::new(AtomicBool::new(true));
        let marker = alive.clone();
        std::thread::spawn(move || {
            let mut owner = Owner {
                c,
                window,
                a,
                formats: Formats::new(),
                saved: None,
                generation: 0,
                alive: marker,
            };
            loop {
                // Serve requests already queued before the restore command.
                if owner.pump().is_err() {
                    break;
                }
                match receive.try_recv() {
                    Ok(Command::Stop) | Err(mpsc::TryRecvError::Disconnected) => break,
                    Ok(Command::Install(text, reply)) => {
                        let _ = reply.send(owner.install(&text));
                    }
                    Ok(Command::Restore(id, reply)) => {
                        let _ = reply.send(owner.restore(id));
                    }
                    Err(mpsc::TryRecvError::Empty) => {}
                }
                std::thread::sleep(Duration::from_millis(2));
            }
            owner.alive.store(false, Ordering::Release);
        });
        Ok(Self { send, alive })
    }
    pub(crate) fn is_alive(&self) -> bool {
        self.alive.load(Ordering::Acquire)
    }
    pub(crate) fn install(&self, text: &str) -> std::result::Result<u64, Reason> {
        let (send, receive) = mpsc::sync_channel(1);
        self.send
            .send(Command::Install(text.into(), send))
            .map_err(|_| Reason::DisplayUnavailable)?;
        receive.recv().map_err(|_| Reason::ClipboardRestoreFailed)?
    }
    pub(crate) fn finish(&self, id: u64, sent: bool) -> std::result::Result<(), Reason> {
        if sent {
            std::thread::sleep(crate::paste::RESTORE_AFTER);
        }
        let (send, receive) = mpsc::sync_channel(1);
        self.send
            .send(Command::Restore(id, send))
            .map_err(|_| Reason::ClipboardRestoreFailed)?;
        receive
            .recv()
            .map_err(|_| Reason::ClipboardRestoreFailed)?
            .map_err(|_| Reason::ClipboardRestoreFailed)?;
        Ok(())
    }
}
impl Drop for Clipboard {
    fn drop(&mut self) {
        let _ = self.send.send(Command::Stop);
    }
}
struct Owner {
    c: RustConnection,
    window: u32,
    a: Atoms,
    formats: Formats,
    saved: Option<Formats>,
    generation: u64,
    alive: Arc<AtomicBool>,
}
impl Owner {
    fn owner(&self) -> Result<u32> {
        Ok(self.c.get_selection_owner(self.a.clipboard)?.reply()?.owner)
    }
    fn read(&mut self, target: u32, deadline: Instant) -> Result<Value> {
        self.c
            .delete_property(self.window, self.a.property)?
            .check()?;
        self.c
            .convert_selection(
                self.window,
                self.a.clipboard,
                target,
                self.a.property,
                CURRENT_TIME,
            )?
            .check()?;
        self.c.flush()?;
        loop {
            ensure!(Instant::now() < deadline, "clipboard read timed out");
            match self.c.poll_for_event()? {
                Some(Event::SelectionNotify(e))
                    if e.selection == self.a.clipboard && e.target == target =>
                {
                    ensure!(e.property != NONE, "clipboard target unavailable");
                    let p = self
                        .c
                        .get_property(
                            true,
                            self.window,
                            e.property,
                            AtomEnum::ANY,
                            0,
                            (CAP / 4) as u32,
                        )?
                        .reply()?;
                    ensure!(
                        matches!(p.format, 8 | 16 | 32)
                            && p.type_ != self.a.incr
                            && p.bytes_after == 0,
                        "incremental or oversized clipboard cannot be snapshotted safely"
                    );
                    return Ok(Value {
                        kind: p.type_,
                        format: p.format,
                        bytes: p.value,
                    });
                }
                Some(e) => {
                    request_result(self.handle(e))?;
                }
                None => std::thread::sleep(Duration::from_millis(2)),
            }
        }
    }
    fn snapshot(&mut self) -> Result<Formats> {
        let owner = self.owner()?;
        if owner == NONE {
            return Ok(Formats::new());
        }
        if owner == self.window {
            return Ok(self.formats.clone());
        }
        let deadline = Instant::now() + DEADLINE;
        let targets = self.read(self.a.targets, deadline)?;
        ensure!(
            targets.format == 32 && targets.kind == u32::from(AtomEnum::ATOM),
            "invalid targets"
        );
        let targets: Vec<u32> = targets
            .bytes
            .chunks_exact(4)
            .map(|v| u32::from_ne_bytes(v.try_into().unwrap()))
            .collect();
        ensure!(targets.len() <= 256, "too many clipboard formats");
        let mut saved = Formats::new();
        let mut size = 0;
        for target in targets {
            if [
                self.a.targets,
                self.a.multiple,
                self.a.timestamp,
                self.a.save,
            ]
            .contains(&target)
            {
                continue;
            }
            let value = self.read(target, deadline)?;
            size += value.bytes.len();
            ensure!(
                size <= CAP && value.bytes.len() + 64 < self.c.maximum_request_bytes(),
                "clipboard too large"
            );
            saved.insert(target, value);
        }
        ensure!(self.owner()? == owner, "clipboard changed during snapshot");
        ensure!(!saved.is_empty(), "clipboard has no restorable targets");
        Ok(saved)
    }
    fn install(&mut self, text: &str) -> std::result::Result<u64, Reason> {
        validate_text(text).map_err(|_| Reason::InputFailed)?;
        if self.saved.is_some() {
            return Err(Reason::PendingPaste);
        }
        let saved = self.snapshot().map_err(|_| Reason::ClipboardUnavailable)?; // No mutation until the full snapshot exists.
        self.generation += 1;
        self.saved = Some(saved);
        self.formats.clear();
        let value = Value {
            kind: self.a.utf8,
            format: 8,
            bytes: text.as_bytes().to_vec(),
        };
        self.formats.insert(self.a.utf8, value.clone());
        self.formats.insert(self.a.plain, value);
        let installed: Result<()> = (|| {
            self.c
                .set_selection_owner(self.window, self.a.clipboard, CURRENT_TIME)?
                .check()?;
            ensure!(self.owner()? == self.window, "could not own clipboard");
            Ok(())
        })();
        if installed.is_err() {
            self.restore(self.generation)
                .map_err(|_| Reason::ClipboardRestoreFailed)?;
            return Err(Reason::ClipboardUnavailable);
        }
        Ok(self.generation)
    }
    fn restore(&mut self, id: u64) -> Result<()> {
        if id != self.generation {
            return Ok(());
        }
        // Make the ownership check and optional release atomic against newer
        // user copies, including when the original selection was empty.
        self.c.grab_server()?.check()?;
        let restored = (|| -> Result<()> {
            let current_owner = self.owner()?;
            if let Some(saved) = self.saved.take() {
                if current_owner == self.window {
                    self.formats = saved;
                    if self.formats.is_empty() {
                        self.c
                            .set_selection_owner(NONE, self.a.clipboard, CURRENT_TIME)?
                            .check()?;
                    }
                } else {
                    self.formats.clear();
                }
            }
            Ok(())
        })();
        let released = self.c.ungrab_server()?.check().map_err(Into::into);
        restored.and(released)
    }
    fn pump(&mut self) -> Result<()> {
        while let Some(e) = self.c.poll_for_event()? {
            request_result(self.handle(e))?;
        }
        self.c.flush()?;
        Ok(())
    }
    fn handle(&mut self, event: Event) -> Result<()> {
        if let Event::SelectionRequest(e) = event {
            let property = if e.property == NONE {
                e.target
            } else {
                e.property
            };
            let mut answer = NONE;
            if e.selection == self.a.clipboard && self.owner()? == self.window {
                if e.target == self.a.targets {
                    let mut targets: Vec<_> = self.formats.keys().copied().collect();
                    targets.push(self.a.targets);
                    self.c
                        .change_property32(
                            PropMode::REPLACE,
                            e.requestor,
                            property,
                            AtomEnum::ATOM,
                            &targets,
                        )?
                        .check()?;
                    answer = property;
                } else if let Some(v) = self.formats.get(&e.target) {
                    self.c
                        .change_property(
                            PropMode::REPLACE,
                            e.requestor,
                            property,
                            v.kind,
                            v.format,
                            (v.bytes.len() / (v.format as usize / 8)) as u32,
                            &v.bytes,
                        )?
                        .check()?;
                    answer = property;
                }
            }
            let reply = SelectionNotifyEvent {
                response_type: SELECTION_NOTIFY_EVENT,
                sequence: 0,
                time: e.time,
                requestor: e.requestor,
                selection: e.selection,
                target: e.target,
                property: answer,
            };
            self.c
                .send_event(false, e.requestor, EventMask::NO_EVENT, reply)?
                .check()?;
        }
        Ok(())
    }
}
