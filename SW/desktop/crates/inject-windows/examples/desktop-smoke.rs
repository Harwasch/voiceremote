//! Synthetic data only. Reads text solely from this process's own test EDIT.
#[cfg(not(windows))]
fn main() {
    println!("SKIPPED: Windows desktop smoke requires Windows");
}

#[cfg(windows)]
fn main() -> voiceremote_core::Result<()> {
    desktop::run()
}

#[cfg(windows)]
mod desktop {
    use std::{
        mem::size_of,
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
            mpsc,
        },
        thread,
        time::{Duration, Instant},
    };
    use voiceremote_core::{InsertionFailure, Result, TextInjector, ensure};
    use voiceremote_inject_windows::{WindowsInjector, focus_snapshot};
    use windows::{
        Win32::{
            Foundation::{HANDLE, HGLOBAL, HINSTANCE, HWND, LPARAM, LRESULT, WPARAM},
            System::{
                DataExchange::*,
                LibraryLoader::GetModuleHandleW,
                Memory::{GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock},
                Ole::{CF_DSPTEXT, CF_UNICODETEXT},
                StationsAndDesktops::*,
                Threading::GetCurrentThreadId,
            },
            UI::{
                Controls::EM_SETREADONLY, Input::KeyboardAndMouse::SetFocus, WindowsAndMessaging::*,
            },
        },
        core::w,
    };

    const SAMPLE: &str = "Synthetic café 漢字 🦀";
    const SENTINEL: &str = "Synthetic clipboard sentinel";
    struct Window(HWND);
    impl Drop for Window {
        fn drop(&mut self) {
            unsafe {
                let _ = DestroyWindow(self.0);
            }
        }
    }
    struct State {
        old: WNDPROC,
        forbidden: bool,
        pastes: Arc<AtomicUsize>,
    }
    struct Subclass {
        hwnd: HWND,
        state: Box<State>,
    }
    impl Drop for Subclass {
        fn drop(&mut self) {
            unsafe {
                if IsWindow(Some(self.hwnd)).as_bool() {
                    SetWindowLongPtrW(self.hwnd, GWLP_USERDATA, 0);
                    if let Some(old) = self.state.old {
                        SetWindowLongPtrW(self.hwnd, GWLP_WNDPROC, old as *const () as isize);
                    }
                }
            }
        }
    }
    unsafe extern "system" fn edit_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
        unsafe {
            let state = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut State;
            if let Some(state) = state.as_mut() {
                if msg == WM_PASTE {
                    state.pastes.fetch_add(1, Ordering::SeqCst);
                }
                if matches!(msg, WM_KEYDOWN | WM_SYSKEYDOWN | WM_CHAR)
                    && matches!(wp.0, 9 | 10 | 13)
                {
                    state.forbidden = true;
                }
                return CallWindowProcW(state.old, hwnd, msg, wp, lp);
            }
            DefWindowProcW(hwnd, msg, wp, lp)
        }
    }
    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain([0]).collect()
    }
    unsafe fn set_data(format: u32, text: &str) -> Result<()> {
        unsafe {
            let text = wide(text);
            let memory = GlobalAlloc(GMEM_MOVEABLE, text.len() * size_of::<u16>())?;
            let ptr = GlobalLock(memory).cast::<u16>();
            ensure!(!ptr.is_null(), "smoke clipboard lock failed");
            std::ptr::copy_nonoverlapping(text.as_ptr(), ptr, text.len());
            let _ = GlobalUnlock(memory);
            SetClipboardData(format, Some(HANDLE(memory.0)))?;
            Ok(())
        }
    }
    fn seed_clipboard(hwnd: HWND, fallback: bool) -> Result<()> {
        unsafe {
            OpenClipboard(Some(hwnd))?;
            let result = (|| -> Result<()> {
                EmptyClipboard()?;
                set_data(CF_UNICODETEXT.0 as u32, SENTINEL)?;
                let format = if fallback {
                    CF_DSPTEXT.0 as u32
                } else {
                    RegisterClipboardFormatW(w!("VoiceRemoteSmokeFormat"))
                };
                ensure!(format != 0, "smoke format registration failed");
                set_data(format, SENTINEL)
            })();
            let _ = CloseClipboard();
            result
        }
    }
    fn check_clipboard(fallback: bool) -> Result<()> {
        unsafe {
            OpenClipboard(None)?;
            let result = (|| -> Result<()> {
                let expected = if fallback { SENTINEL } else { SAMPLE };
                let formats = if fallback {
                    vec![CF_UNICODETEXT.0 as u32, CF_DSPTEXT.0 as u32]
                } else {
                    vec![CF_UNICODETEXT.0 as u32]
                };
                for format in formats {
                    let data = HGLOBAL(GetClipboardData(format)?.0);
                    ensure!(
                        GlobalSize(data) >= wide(expected).len() * 2,
                        "smoke clipboard size mismatch"
                    );
                    let ptr = GlobalLock(data).cast::<u16>();
                    ensure!(!ptr.is_null(), "smoke cannot read restored clipboard");
                    let matches =
                        std::slice::from_raw_parts(ptr, expected.encode_utf16().count() + 1)
                            == wide(expected);
                    let _ = GlobalUnlock(data);
                    ensure!(matches, "smoke clipboard disposition mismatch");
                }
                if !fallback {
                    for name in ["CanIncludeInClipboardHistory", "CanUploadToCloudClipboard"] {
                        let name = wide(name);
                        let format = RegisterClipboardFormatW(windows::core::PCWSTR(name.as_ptr()));
                        let data = HGLOBAL(GetClipboardData(format)?.0);
                        ensure!(GlobalSize(data) >= 4, "smoke privacy marker missing");
                        let ptr = GlobalLock(data).cast::<u32>();
                        ensure!(!ptr.is_null(), "smoke privacy marker unreadable");
                        let value = *ptr;
                        let _ = GlobalUnlock(data);
                        ensure!(value == 0, "smoke privacy opt-out missing");
                    }
                }
                Ok(())
            })();
            let _ = CloseClipboard();
            result
        }
    }
    fn pump() {
        unsafe {
            let mut msg = MSG::default();
            while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
    }
    unsafe fn desktop_name(handle: HANDLE) -> windows::core::Result<Vec<u16>> {
        unsafe {
            let mut name = [0u16; 256];
            let mut used = 0;
            GetUserObjectInformationW(
                handle,
                UOI_NAME,
                Some(name.as_mut_ptr().cast()),
                size_of_val(&name) as u32,
                Some(&mut used),
            )?;
            Ok(name[..used as usize / 2].to_vec())
        }
    }
    fn desktop_skip_reason() -> Option<String> {
        unsafe {
            let input = match OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_READOBJECTS)
            {
                Ok(input) => input,
                Err(error) => {
                    return Some(format!(
                        "input desktop inaccessible, HRESULT=0x{:08x}",
                        error.code().0 as u32
                    ));
                }
            };
            let check = (|| -> windows::core::Result<Option<String>> {
                let station = GetProcessWindowStation()?;
                let mut flags = USEROBJECTFLAGS::default();
                GetUserObjectInformationW(
                    HANDLE(station.0),
                    UOI_FLAGS,
                    Some((&mut flags as *mut USEROBJECTFLAGS).cast()),
                    size_of::<USEROBJECTFLAGS>() as u32,
                    None,
                )?;
                if flags.dwFlags & WSF_VISIBLE as u32 == 0 {
                    return Ok(Some(
                        "process window station is not visible (service session)".into(),
                    ));
                }
                let current = GetThreadDesktop(GetCurrentThreadId())?;
                if desktop_name(HANDLE(current.0))? != desktop_name(HANDLE(input.0))? {
                    return Ok(Some(
                        "runner thread is not on the input desktop (locked/secure desktop)".into(),
                    ));
                }
                Ok(None)
            })();
            let _ = CloseDesktop(input);
            check.unwrap_or_else(|error| {
                Some(format!(
                    "desktop eligibility query failed, HRESULT=0x{:08x}",
                    error.code().0 as u32
                ))
            })
        }
    }
    pub fn run() -> Result<()> {
        if std::env::args().any(|arg| arg == "--manual") {
            println!("Focus a scratch field within 8 seconds. Synthetic text only.");
            thread::sleep(Duration::from_secs(8));
            let focus = focus_snapshot();
            println!(
                "focused={} last_activity_at={}",
                focus.text_field_focused, focus.last_activity_at
            );
            match WindowsInjector.insert_text(SAMPLE) {
                Err(error)
                    if error.downcast_ref::<InsertionFailure>()
                        == Some(&InsertionFailure::Unconfirmed) =>
                {
                    println!(
                        "UNCONFIRMED: clipboard read is not insertion proof; dictated text retained for late paste. Verify the scratch field manually; do not retry automatically."
                    );
                }
                result => {
                    result?;
                    println!(
                        "Unicode input accepted; visually verify the scratch field and no submission."
                    );
                }
            }
            return Ok(());
        }
        if let Some(reason) = desktop_skip_reason() {
            println!("SKIPPED: {reason}");
            return Ok(());
        }
        // This mode intentionally seeds the clipboard with synthetic fixtures.
        // Run it in an isolated test session (CI); use --manual on the laptop.
        unsafe {
            let module = HINSTANCE(GetModuleHandleW(None)?.0);
            let parent = Window(CreateWindowExW(
                WINDOW_EX_STYLE(0),
                w!("STATIC"),
                w!("VoiceRemote synthetic smoke"),
                WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                50,
                50,
                600,
                200,
                None,
                None,
                Some(module),
                None,
            )?);
            let edit = CreateWindowExW(
                WINDOW_EX_STYLE(0),
                w!("EDIT"),
                w!(""),
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | WINDOW_STYLE(ES_MULTILINE as u32),
                10,
                10,
                550,
                120,
                Some(parent.0),
                None,
                Some(module),
                None,
            )?;
            let mut state = Box::new(State {
                old: None,
                forbidden: false,
                pastes: Arc::new(AtomicUsize::new(0)),
            });
            let pastes = state.pastes.clone();
            let old = SetWindowLongPtrW(edit, GWLP_WNDPROC, edit_proc as *const () as isize);
            ensure!(old != 0, "cannot subclass owned smoke edit");
            state.old = Some(std::mem::transmute::<
                isize,
                unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT,
            >(old));
            SetWindowLongPtrW(edit, GWLP_USERDATA, &mut *state as *mut State as isize);
            let subclass = Subclass { hwnd: edit, state };
            let _ = SetForegroundWindow(parent.0);
            let _ = SetFocus(Some(edit));
            let deadline = Instant::now() + Duration::from_secs(3);
            while GetForegroundWindow() != parent.0 && Instant::now() < deadline {
                pump();
                thread::sleep(Duration::from_millis(10));
            }
            if GetForegroundWindow() != parent.0 {
                // Destroy the subclassed window before its Rust userdata.
                drop(parent);
                println!(
                    "SKIPPED: runner has no usable foreground desktop (locked, service session, or foreground policy)"
                );
                return Ok(());
            }
            let (send, receive) = mpsc::channel();
            let raw = parent.0.0 as usize;
            let raw_edit = edit.0 as usize;
            let worker = thread::spawn(move || {
                let result = (|| -> Result<()> {
                    let deadline = Instant::now() + Duration::from_secs(3);
                    while !focus_snapshot().text_field_focused && Instant::now() < deadline {
                        thread::sleep(Duration::from_millis(20));
                    }
                    ensure!(
                        focus_snapshot().text_field_focused,
                        "UI Automation did not recognize the smoke edit field"
                    );
                    for fallback in [false, true] {
                        seed_clipboard(HWND(raw as *mut _), fallback)?;
                        let result = WindowsInjector.insert_text(SAMPLE);
                        if fallback {
                            result?;
                        } else {
                            let error =
                                result.expect_err("paste must not claim generic insertion success");
                            ensure!(
                                error.downcast_ref::<InsertionFailure>()
                                    == Some(&InsertionFailure::Unconfirmed),
                                "smoke paste failed before input"
                            );
                            ensure!(
                                pastes.load(Ordering::SeqCst) == 1,
                                "smoke did not observe WM_PASTE; fallback cannot prove paste"
                            );
                        }
                        check_clipboard(fallback)?;
                    }
                    for forbidden in ["Synthetic\r", "Synthetic\n", "Synthetic\t"] {
                        ensure!(
                            WindowsInjector.insert_text(forbidden).is_err(),
                            "injector accepted a forbidden control"
                        );
                    }
                    let edit = HWND(raw_edit as *mut _);
                    // SendInput acceptance precedes delivery. Wait for our
                    // own EDIT to consume Unicode events before making it
                    // read-only (sent window messages can overtake input).
                    let deadline = Instant::now() + Duration::from_secs(2);
                    loop {
                        let mut text = [0u16; 256];
                        let len = GetWindowTextW(edit, &mut text) as usize;
                        if String::from_utf16_lossy(&text[..len]) == SAMPLE.repeat(2) {
                            break;
                        }
                        ensure!(
                            Instant::now() < deadline,
                            "smoke Unicode readback timed out (contents withheld)"
                        );
                        thread::sleep(Duration::from_millis(10));
                    }
                    SendMessageW(edit, EM_SETREADONLY, Some(WPARAM(1)), None);
                    ensure!(
                        !focus_snapshot().text_field_focused,
                        "read-only edit reported as focused"
                    );
                    ensure!(
                        WindowsInjector.insert_text(SAMPLE).is_err(),
                        "read-only injection succeeded"
                    );
                    check_clipboard(true)?;
                    SendMessageW(edit, EM_SETREADONLY, Some(WPARAM(0)), None);
                    Ok(())
                })();
                let _ = send.send(result);
            });
            let deadline = Instant::now() + Duration::from_secs(45);
            let result = loop {
                pump();
                match receive.try_recv() {
                    Ok(result) => break result,
                    Err(mpsc::TryRecvError::Disconnected) => {
                        break Err(voiceremote_core::anyhow!("smoke worker disconnected"));
                    }
                    Err(mpsc::TryRecvError::Empty) => {}
                }
                if Instant::now() >= deadline {
                    break Err(voiceremote_core::anyhow!("smoke timed out"));
                }
                thread::sleep(Duration::from_millis(5));
            };
            // Read only our own known HWND, never the arbitrary focused field.
            let readback_deadline = Instant::now() + Duration::from_secs(2);
            let actual = loop {
                pump();
                let mut text = vec![0u16; 256];
                let len = GetWindowTextW(edit, &mut text) as usize;
                text.truncate(len);
                let actual = String::from_utf16(&text)?;
                if actual == SAMPLE.repeat(2) || Instant::now() >= readback_deadline {
                    break actual;
                }
                thread::sleep(Duration::from_millis(10));
            };
            let forbidden = subclass.state.forbidden;
            let paste_count = subclass.state.pastes.load(Ordering::SeqCst);
            drop(parent);
            if result.is_ok() {
                worker
                    .join()
                    .map_err(|_| voiceremote_core::anyhow!("smoke worker failed"))?;
            }
            result?;
            ensure!(
                paste_count == 1,
                "smoke must observe exactly one WM_PASTE and none in Unicode fallback"
            );
            ensure!(
                actual == SAMPLE.repeat(2),
                "smoke text mismatch (contents withheld)"
            );
            ensure!(
                !actual.contains(['\r', '\n', '\t']) && !forbidden,
                "smoke observed Enter, Tab, or a newline"
            );
            println!(
                "PASS: UIA focus/read-only denial; WM_PASTE observed; unconfirmed paste retained privately; Unicode fallback preserves clipboard; exact synthetic readback; no Enter/Tab/newline"
            );
            Ok(())
        }
    }
}
