//! CI-only real X server readback using a small synthetic text field.
#![cfg(target_os = "linux")]
mod a11y;
use std::{
    collections::BTreeMap,
    sync::mpsc,
    time::{Duration, Instant},
};
use voiceremote_core::TextInjector;
use voiceremote_inject_linux::LinuxInjector;
use x11rb::{
    CURRENT_TIME, NONE,
    connection::Connection,
    protocol::{Event, xproto::*},
    rust_connection::RustConnection,
    wrapper::ConnectionExt as _,
};

struct Field {
    c: RustConnection,
    window: u32,
    clipboard: u32,
    manager: u32,
    read_at: Option<Instant>,
    targets: u32,
    utf8: u32,
    property: u32,
    saved: BTreeMap<u32, Vec<u8>>,
    buffer: String,
    keys: Vec<u32>,
    consume: bool,
    copy_during_paste: bool,
    unreadable: bool,
    terminal: bool,
    quote_pending: bool,
}
impl Field {
    fn new() -> Self {
        let (c, screen) = x11rb::connect(None).unwrap();
        let root = c.setup().roots[screen].root;
        let atom = |s: &[u8]| c.intern_atom(false, s).unwrap().reply().unwrap().atom;
        let clipboard = atom(b"CLIPBOARD");
        let targets = atom(b"TARGETS");
        let utf8 = atom(b"UTF8_STRING");
        let property = atom(b"TEST_FIELD_SELECTION");
        let active = atom(b"_NET_ACTIVE_WINDOW");
        let saved = BTreeMap::from([
            (utf8, b"synthetic clipboard".to_vec()),
            (atom(b"image/png"), vec![1, 2, 3, 4]),
            (atom(b"text/html"), b"<b>fixture</b>".to_vec()),
        ]);
        let window = c.generate_id().unwrap();
        c.create_window(
            0,
            window,
            root,
            0,
            0,
            300,
            100,
            0,
            WindowClass::INPUT_OUTPUT,
            0,
            &CreateWindowAux::new().event_mask(
                EventMask::KEY_PRESS | EventMask::KEY_RELEASE | EventMask::PROPERTY_CHANGE,
            ),
        )
        .unwrap()
        .check()
        .unwrap();
        let manager = c.generate_id().unwrap();
        c.create_window(
            0,
            manager,
            root,
            0,
            0,
            1,
            1,
            0,
            WindowClass::INPUT_OUTPUT,
            0,
            &CreateWindowAux::new(),
        )
        .unwrap()
        .check()
        .unwrap();
        c.map_window(window).unwrap().check().unwrap();
        c.set_input_focus(InputFocus::PARENT, window, CURRENT_TIME)
            .unwrap()
            .check()
            .unwrap();
        c.change_property32(PropMode::REPLACE, root, active, AtomEnum::WINDOW, &[window])
            .unwrap()
            .check()
            .unwrap();
        c.set_selection_owner(window, clipboard, CURRENT_TIME)
            .unwrap()
            .check()
            .unwrap();
        c.flush().unwrap();
        Self {
            c,
            window,
            clipboard,
            manager,
            read_at: None,
            targets,
            utf8,
            property,
            saved,
            buffer: String::new(),
            keys: vec![],
            consume: true,
            copy_during_paste: false,
            unreadable: false,
            terminal: false,
            quote_pending: false,
        }
    }
    fn event(&mut self, event: Event) -> Option<Vec<u8>> {
        match event {
            Event::SelectionRequest(e) => {
                let property = if e.property == NONE {
                    e.target
                } else {
                    e.property
                };
                let mut answer = NONE;
                if e.target == self.targets && !self.unreadable {
                    let mut targets = self.saved.keys().copied().collect::<Vec<_>>();
                    targets.push(self.targets);
                    self.c
                        .change_property32(
                            PropMode::REPLACE,
                            e.requestor,
                            property,
                            AtomEnum::ATOM,
                            &targets,
                        )
                        .unwrap()
                        .check()
                        .unwrap();
                    answer = property;
                } else if let Some(bytes) = self.saved.get(&e.target) {
                    self.c
                        .change_property8(PropMode::REPLACE, e.requestor, property, e.target, bytes)
                        .unwrap()
                        .check()
                        .unwrap();
                    answer = property;
                }
                self.c
                    .send_event(
                        false,
                        e.requestor,
                        EventMask::NO_EVENT,
                        SelectionNotifyEvent {
                            response_type: SELECTION_NOTIFY_EVENT,
                            sequence: 0,
                            time: e.time,
                            requestor: e.requestor,
                            selection: e.selection,
                            target: e.target,
                            property: answer,
                        },
                    )
                    .unwrap()
                    .check()
                    .unwrap();
            }
            Event::KeyPress(e) => {
                let reply = self
                    .c
                    .get_keyboard_mapping(e.detail, 1)
                    .unwrap()
                    .reply()
                    .unwrap();
                let caps = e.state.contains(KeyButMask::LOCK)
                    && (reply.keysyms[0] as u8).is_ascii_alphabetic();
                let sym = reply.keysyms[usize::from(e.state.contains(KeyButMask::SHIFT) ^ caps)];
                self.keys.push(sym);
                assert!(
                    ![0xff0d, 0xff09, 0xff8d, 0xfe20].contains(&sym),
                    "submit/navigation key emitted"
                );
                if [b'v' as u32, b'V' as u32].contains(&sym)
                    && e.state.contains(KeyButMask::CONTROL)
                {
                    if self.terminal && !e.state.contains(KeyButMask::SHIFT) {
                        self.quote_pending = true;
                        return None;
                    }
                    // An immediate manager read must not restore early or prove
                    // delivery; the actual field requests it 400 ms later.
                    self.c
                        .convert_selection(
                            self.manager,
                            self.clipboard,
                            self.utf8,
                            self.property,
                            CURRENT_TIME,
                        )
                        .unwrap()
                        .check()
                        .unwrap();
                    if self.consume {
                        self.read_at = Some(Instant::now() + Duration::from_millis(400));
                    }
                } else if !e.state.contains(KeyButMask::CONTROL) && sym < 0x100 && sym >= 0x20 {
                    self.buffer.push(char::from_u32(sym).unwrap());
                }
            }
            Event::SelectionNotify(e) if e.property != NONE => {
                if e.requestor == self.manager {
                    self.c
                        .delete_property(self.manager, e.property)
                        .unwrap()
                        .check()
                        .unwrap();
                    return None;
                }
                let bytes = self
                    .c
                    .get_property(true, self.window, e.property, AtomEnum::ANY, 0, 1024 * 1024)
                    .unwrap()
                    .reply()
                    .unwrap()
                    .value;
                return Some(bytes);
            }
            _ => {}
        }
        self.c.flush().unwrap();
        None
    }
    fn inject(&mut self, injector: &mut LinuxInjector, text: &str) -> anyhow::Result<()> {
        let mut worker = injector.clone();
        let text = text.to_string();
        let (send, receive) = mpsc::sync_channel(1);
        let join = std::thread::spawn(move || {
            send.send(worker.insert_text(&text)).unwrap();
        });
        let end = Instant::now() + Duration::from_secs(35);
        let result = loop {
            assert!(Instant::now() < end, "injection timed out");
            if self.read_at.is_some_and(|at| Instant::now() >= at) {
                self.read_at = None;
                self.c
                    .convert_selection(
                        self.window,
                        self.clipboard,
                        self.utf8,
                        self.property,
                        CURRENT_TIME,
                    )
                    .unwrap()
                    .check()
                    .unwrap();
            }
            while let Some(event) = self.c.poll_for_event().unwrap() {
                if let Some(bytes) = self.event(event) {
                    self.buffer.push_str(std::str::from_utf8(&bytes).unwrap());
                    if self.copy_during_paste {
                        self.saved
                            .insert(self.utf8, b"synthetic newer copy".to_vec());
                        self.c
                            .set_selection_owner(self.window, self.clipboard, CURRENT_TIME)
                            .unwrap()
                            .check()
                            .unwrap();
                    }
                }
            }
            if let Ok(result) = receive.try_recv() {
                break result;
            }
            std::thread::sleep(Duration::from_millis(2));
        };
        join.join().unwrap();
        // Drain input events already acknowledged by the injector's X round trip.
        for _ in 0..10 {
            while let Some(event) = self.c.poll_for_event().unwrap() {
                if let Some(bytes) = self.event(event) {
                    self.buffer.push_str(std::str::from_utf8(&bytes).unwrap());
                }
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        result
    }
    fn read(&mut self, target: u32) -> Vec<u8> {
        self.c
            .convert_selection(
                self.window,
                self.clipboard,
                target,
                self.property,
                CURRENT_TIME,
            )
            .unwrap()
            .check()
            .unwrap();
        let end = Instant::now() + Duration::from_secs(3);
        loop {
            assert!(Instant::now() < end, "selection read timed out");
            if let Some(event) = self.c.poll_for_event().unwrap() {
                if let Some(bytes) = self.event(event) {
                    return bytes;
                }
            } else {
                std::thread::sleep(Duration::from_millis(2));
            }
        }
    }
}

#[test]
#[ignore = "CI only: xvfb-run with XDG_SESSION_TYPE=x11"]
fn xvfb_inject_readback_restore_and_never_enter() {
    use std::sync::atomic::Ordering;
    use x11rb::protocol::xkb::{ConnectionExt as _, ID};
    let a11y = a11y::Accessibility::new();
    let state = tempfile::tempdir().unwrap();
    let mut injector = LinuxInjector::new(state.path().into());
    let mut field = Field::new();
    let expected = "synthetic é 日本語 🦀 -- literal fixture";
    let started = Instant::now();
    let error = field.inject(&mut injector, expected).unwrap_err();
    assert_eq!(
        error.downcast_ref::<voiceremote_core::InsertionFailure>(),
        Some(&voiceremote_core::InsertionFailure::Unconfirmed)
    );
    assert!(started.elapsed() >= Duration::from_secs(30));
    assert!(started.elapsed() < Duration::from_secs(35));
    assert_eq!(field.buffer, expected);
    assert!(!field.buffer.contains(['\r', '\n', '\t']));
    // Automatic bounded restoration, even when a manager was the first reader.
    for (target, expected) in field.saved.clone() {
        assert_eq!(field.read(target), expected);
    }
    let keys_before = field.keys.len();
    for text in [
        "fixture\n",
        "fixture\r",
        "fixture\t",
        "fixture\u{1b}",
        "fixture\u{85}",
        "fixture\u{2028}",
    ] {
        assert!(field.inject(&mut injector, text).is_err());
    }
    assert_eq!(field.keys.len(), keys_before);
    // Start empty: restoration must never release a newer user selection.
    field
        .c
        .set_selection_owner(NONE, field.clipboard, CURRENT_TIME)
        .unwrap()
        .check()
        .unwrap();
    field.copy_during_paste = true;
    field.buffer.clear();
    assert!(
        field
            .inject(&mut injector, "synthetic second paste")
            .is_err()
    );
    assert_eq!(field.buffer, "synthetic second paste");
    assert_eq!(field.read(field.utf8), b"synthetic newer copy");
    field.copy_during_paste = false;
    field.consume = false;
    field.buffer.clear();
    assert!(
        field
            .inject(&mut injector, "synthetic ignored paste")
            .is_err()
    );
    assert!(field.buffer.is_empty());
    assert_eq!(field.read(field.utf8), b"synthetic newer copy");
    field.unreadable = true;
    field.consume = true;
    field.buffer.clear();
    field
        .c
        .set_selection_owner(field.window, field.clipboard, CURRENT_TIME)
        .unwrap()
        .check()
        .unwrap();
    field.inject(&mut injector, "fallback fixture").unwrap();
    assert_eq!(field.buffer, "fallback fixture");
    // Both locks are retained. Paste shortcuts work and typing compensates Caps.
    field.c.xkb_use_extension(1, 0).unwrap().reply().unwrap();
    field
        .c
        .xkb_latch_lock_state(
            ID::USE_CORE_KBD.into(),
            ModMask::LOCK | ModMask::M2,
            ModMask::LOCK | ModMask::M2,
            false,
            0.into(),
            ModMask::default(),
            false,
            0,
        )
        .unwrap()
        .check()
        .unwrap();
    field.buffer.clear();
    field.inject(&mut injector, "Abc locks fixture").unwrap();
    assert_eq!(field.buffer, "Abc locks fixture");
    field.unreadable = false;
    field.buffer.clear();
    assert!(
        field
            .inject(&mut injector, "synthetic locked paste")
            .is_err()
    );
    assert_eq!(field.buffer, "synthetic locked paste");
    // Dying external selection requestors do not terminate our owner thread.
    let doomed = field.c.generate_id().unwrap();
    field
        .c
        .create_window(
            0,
            doomed,
            field.c.setup().roots[0].root,
            0,
            0,
            1,
            1,
            0,
            WindowClass::INPUT_OUTPUT,
            0,
            &CreateWindowAux::new(),
        )
        .unwrap()
        .check()
        .unwrap();
    let owner = field
        .c
        .get_selection_owner(field.clipboard)
        .unwrap()
        .reply()
        .unwrap()
        .owner;
    field.c.destroy_window(doomed).unwrap().check().unwrap();
    field
        .c
        .send_event(
            false,
            owner,
            EventMask::NO_EVENT,
            SelectionRequestEvent {
                response_type: SELECTION_REQUEST_EVENT,
                sequence: 0,
                time: CURRENT_TIME,
                owner,
                requestor: doomed,
                selection: field.clipboard,
                target: field.utf8,
                property: field.property,
            },
        )
        .unwrap()
        .check()
        .unwrap();
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(field.read(field.utf8), b"synthetic newer copy");
    // Terminal class and role require Ctrl+Shift+V; plain Ctrl+V is a trap.
    field
        .c
        .change_property8(
            PropMode::REPLACE,
            field.window,
            AtomEnum::WM_CLASS,
            AtomEnum::STRING,
            b"xterm\0XTerm\0",
        )
        .unwrap()
        .check()
        .unwrap();
    field.terminal = true;
    a11y.role.store(60, Ordering::SeqCst);
    field.buffer.clear();
    assert!(field.inject(&mut injector, "synthetic terminal").is_err());
    assert_eq!(field.buffer, "synthetic terminal");
    assert!(!field.quote_pending);
    for role in [40, 79] {
        a11y.role.store(role, Ordering::SeqCst);
        a11y.large.store(role == 79, Ordering::SeqCst);
        field.buffer.clear();
        let keys = field.keys.len();
        assert!(field.inject(&mut injector, "synthetic denied").is_err());
        assert!(field.buffer.is_empty());
        assert_eq!(field.keys.len(), keys);
    }
    a11y.large.store(false, Ordering::SeqCst);
    a11y.stalled.store(true, Ordering::SeqCst);
    field.buffer.clear();
    let keys = field.keys.len();
    assert!(field.inject(&mut injector, "synthetic timeout").is_err());
    assert!(field.buffer.is_empty());
    assert_eq!(field.keys.len(), keys);
}
