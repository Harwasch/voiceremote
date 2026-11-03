//! Synthetic data only. Reads text solely from this process's own test EDIT.
// Acquisition is environmental; once it succeeds, wrong injection/readback
// results must stay failures. Keep this boundary testable without a desktop.
#[cfg(any(windows, test))]
#[derive(Debug)]
struct DesktopAccessDenied(&'static str);
#[cfg(any(windows, test))]
impl std::fmt::Display for DesktopAccessDenied {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{}: input desktop access denied (HRESULT=0x80070005)",
            self.0
        )
    }
}
#[cfg(any(windows, test))]
impl std::error::Error for DesktopAccessDenied {}

// Only calls requiring an interactive window station can classify access
// denial as environmental. Data verification and all other errors still fail.
#[cfg(any(windows, test))]
fn smoke_call<T>(
    operation: &'static str,
    result: Result<T, u32>,
    desktop_sensitive: bool,
) -> voiceremote_core::Result<T> {
    result.map_err(|code| {
        if desktop_sensitive && code == 0x80070005 {
            DesktopAccessDenied(operation).into()
        } else {
            voiceremote_core::anyhow!("{operation} failed (HRESULT=0x{code:08x})")
        }
    })
}
#[cfg(any(windows, test))]
fn with_input_desktop<T>(
    acquire: impl FnOnce() -> voiceremote_core::Result<T>,
    exercise: impl FnOnce(&T) -> voiceremote_core::Result<()>,
) -> voiceremote_core::Result<Option<String>> {
    let desktop = match acquire() {
        Ok(desktop) => desktop,
        Err(error) => return Ok(Some(format!("cannot acquire input desktop: {error:#}"))),
    };
    match exercise(&desktop) {
        Ok(()) => Ok(None),
        Err(error) if error.downcast_ref::<DesktopAccessDenied>().is_some() => {
            Ok(Some(error.to_string()))
        }
        Err(error) => Err(error),
    }
}
#[cfg(test)]
mod environment_tests {
    use super::*;
    #[test]
    fn denied_input_desktop_skips_without_exercising_input() {
        let result = with_input_desktop(
            || -> voiceremote_core::Result<()> {
                Err(voiceremote_core::anyhow!(
                    "input desktop inaccessible, HRESULT=0x80070005"
                ))
            },
            |_| panic!("must not create windows or queue input"),
        )
        .unwrap();
        assert!(result.unwrap().contains("0x80070005"));
    }
    #[test]
    fn denied_window_or_clipboard_setup_skips_with_the_failing_api() {
        for operation in [
            "CreateWindowExW(parent)",
            "CreateWindowExW(edit)",
            "SetWindowLongPtrW",
            "SetFocus",
            "OpenClipboard(seed)",
            "OpenClipboard(check)",
            "EmptyClipboard(seed)",
            "SetClipboardData(seed)",
        ] {
            let result =
                with_input_desktop(|| Ok(()), |_| smoke_call(operation, Err(0x80070005), true))
                    .unwrap();
            let reason = result.expect("environmental denial must skip");
            assert!(reason.contains(operation));
            assert!(reason.contains("0x80070005"));
        }
    }
    #[test]
    fn unavailable_formats_and_other_api_errors_never_skip() {
        for (operation, code, sensitive) in [
            ("GetClipboardData(check)", 0x80070005, false),
            ("GetClipboardData(privacy)", 0x80070005, false),
            ("GlobalAlloc(seed)", 0x80070005, false),
            ("CreateWindowExW(parent)", 0x8007000e, true),
        ] {
            let error =
                with_input_desktop(|| Ok(()), |_| smoke_call(operation, Err(code), sensitive))
                    .unwrap_err();
            assert!(error.to_string().contains(operation));
        }
    }
    #[test]
    fn usable_desktop_wrong_readback_is_a_failure() {
        assert!(
            with_input_desktop(
                || Ok(()),
                |_| Err(voiceremote_core::anyhow!("synthetic readback mismatch"))
            )
            .is_err()
        );
        assert_eq!(with_input_desktop(|| Ok(()), |_| Ok(())).unwrap(), None);
    }
}

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
            Foundation::{
                GetLastError, HANDLE, HGLOBAL, HINSTANCE, HWND, LPARAM, LRESULT, SetLastError,
                WIN32_ERROR, WPARAM,
            },
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

    fn api<T>(
        operation: &'static str,
        result: windows::core::Result<T>,
        sensitive: bool,
    ) -> Result<T> {
        super::smoke_call(
            operation,
            result.map_err(|error| error.code().0 as u32),
            sensitive,
        )
    }
    // These APIs return zero both on success and failure. Clear LastError first
    // so an old access denial cannot convert a wrong result into a skip.
    unsafe fn set_window_long(
        hwnd: HWND,
        index: WINDOW_LONG_PTR_INDEX,
        value: isize,
    ) -> Result<isize> {
        unsafe {
            SetLastError(WIN32_ERROR(0));
            let old = SetWindowLongPtrW(hwnd, index, value);
            if old == 0 && GetLastError().0 != 0 {
                api(
                    "SetWindowLongPtrW",
                    Err::<(), _>(windows::core::Error::from_win32()),
                    true,
                )?;
            }
            Ok(old)
        }
    }
    unsafe fn read_edit(edit: HWND, text: &mut [u16]) -> Result<usize> {
        unsafe {
            SetLastError(WIN32_ERROR(0));
            let len = GetWindowTextW(edit, text);
            if len == 0 && GetLastError().0 != 0 {
                api(
                    "GetWindowTextW(owned edit)",
                    Err::<(), _>(windows::core::Error::from_win32()),
                    true,
                )?;
            }
            Ok(len as usize)
        }
    }
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
    unsafe fn register_format(name: windows::core::PCWSTR) -> Result<u32> {
        unsafe {
            SetLastError(WIN32_ERROR(0));
            let format = RegisterClipboardFormatW(name);
            if format == 0 {
                api(
                    "RegisterClipboardFormatW",
                    Err::<(), _>(windows::core::Error::from_win32()),
                    true,
                )?;
            }
            Ok(format)
        }
    }
    unsafe fn set_data(format: u32, text: &str) -> Result<()> {
        unsafe {
            let text = wide(text);
            let memory = api(
                "GlobalAlloc(seed)",
                GlobalAlloc(GMEM_MOVEABLE, text.len() * size_of::<u16>()),
                false,
            )?;
            let ptr = GlobalLock(memory).cast::<u16>();
            ensure!(!ptr.is_null(), "smoke clipboard lock failed");
            std::ptr::copy_nonoverlapping(text.as_ptr(), ptr, text.len());
            let _ = GlobalUnlock(memory);
            api(
                "SetClipboardData(seed)",
                SetClipboardData(format, Some(HANDLE(memory.0))),
                true,
            )?;
            Ok(())
        }
    }
    fn seed_clipboard(hwnd: HWND, fallback: bool) -> Result<()> {
        unsafe {
            api("OpenClipboard(seed)", OpenClipboard(Some(hwnd)), true)?;
            let result = (|| -> Result<()> {
                api("EmptyClipboard(seed)", EmptyClipboard(), true)?;
                set_data(CF_UNICODETEXT.0 as u32, SENTINEL)?;
                let format = if fallback {
                    CF_DSPTEXT.0 as u32
                } else {
                    register_format(w!("VoiceRemoteSmokeFormat"))?
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
            api("OpenClipboard(check)", OpenClipboard(None), true)?;
            let result = (|| -> Result<()> {
                let expected = if fallback { SENTINEL } else { SAMPLE };
                let formats = if fallback {
                    vec![CF_UNICODETEXT.0 as u32, CF_DSPTEXT.0 as u32]
                } else {
                    vec![CF_UNICODETEXT.0 as u32]
                };
                for format in formats {
                    let data =
                        HGLOBAL(api("GetClipboardData(check)", GetClipboardData(format), false)?.0);
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
                        let format = register_format(windows::core::PCWSTR(name.as_ptr()))?;
                        let data = HGLOBAL(
                            api("GetClipboardData(privacy)", GetClipboardData(format), false)?.0,
                        );
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
    struct InputDesktop {
        input: HDESK,
        previous: HDESK,
    }
    impl Drop for InputDesktop {
        fn drop(&mut self) {
            unsafe {
                let _ = SetThreadDesktop(self.previous);
                let _ = CloseDesktop(self.input);
            }
        }
    }
    fn acquire_input_desktop() -> Result<InputDesktop> {
        unsafe {
            // READOBJECTS alone can succeed on a runner that cannot create a
            // window or bind this thread to the input desktop. Acquire the same
            // rights the smoke needs before creating any HWND or queuing input.
            let input = OpenInputDesktop(
                DESKTOP_CONTROL_FLAGS(0),
                false,
                DESKTOP_ACCESS_FLAGS(
                    DESKTOP_CREATEWINDOW.0 | DESKTOP_READOBJECTS.0 | DESKTOP_WRITEOBJECTS.0,
                ),
            )
            .map_err(|e| {
                voiceremote_core::anyhow!(
                    "OpenInputDesktop failed, HRESULT=0x{:08x}",
                    e.code().0 as u32
                )
            })?;
            let acquired = (|| -> Result<HDESK> {
                let station = api("GetProcessWindowStation", GetProcessWindowStation(), true)?;
                let mut flags = USEROBJECTFLAGS::default();
                api(
                    "GetUserObjectInformationW(window station)",
                    GetUserObjectInformationW(
                        HANDLE(station.0),
                        UOI_FLAGS,
                        Some((&mut flags as *mut USEROBJECTFLAGS).cast()),
                        size_of::<USEROBJECTFLAGS>() as u32,
                        None,
                    ),
                    true,
                )?;
                ensure!(
                    flags.dwFlags & WSF_VISIBLE as u32 != 0,
                    "process window station is not visible (service session)"
                );
                let previous = api(
                    "GetThreadDesktop",
                    GetThreadDesktop(GetCurrentThreadId()),
                    true,
                )?;
                // Retain the assigned desktop throughout the smoke. New worker
                // threads also acquire it explicitly before UIA or injection.
                SetThreadDesktop(input).map_err(|e| {
                    voiceremote_core::anyhow!(
                        "SetThreadDesktop failed, HRESULT=0x{:08x}",
                        e.code().0 as u32
                    )
                })?;
                Ok(previous)
            })();
            match acquired {
                Ok(previous) => Ok(InputDesktop { input, previous }),
                Err(error) => {
                    let _ = CloseDesktop(input);
                    Err(error)
                }
            }
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
        let skipped = super::with_input_desktop(acquire_input_desktop, |_| exercise())?;
        if let Some(reason) = skipped {
            println!("SKIPPED: {reason}");
        }
        Ok(())
    }
    fn exercise() -> Result<()> {
        // This mode intentionally seeds the clipboard with synthetic fixtures.
        // Run it in an isolated test session (CI); use --manual on the laptop.
        unsafe {
            let module = HINSTANCE(api("GetModuleHandleW", GetModuleHandleW(None), false)?.0);
            let parent = Window(api(
                "CreateWindowExW(parent)",
                CreateWindowExW(
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
                ),
                true,
            )?);
            let edit = api(
                "CreateWindowExW(edit)",
                CreateWindowExW(
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
                ),
                true,
            )?;
            let mut state = Box::new(State {
                old: None,
                forbidden: false,
                pastes: Arc::new(AtomicUsize::new(0)),
            });
            let pastes = state.pastes.clone();
            let old = set_window_long(edit, GWLP_WNDPROC, edit_proc as *const () as isize)?;
            ensure!(old != 0, "cannot subclass owned smoke edit");
            state.old = Some(std::mem::transmute::<
                isize,
                unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT,
            >(old));
            set_window_long(edit, GWLP_USERDATA, &mut *state as *mut State as isize)?;
            let subclass = Subclass { hwnd: edit, state };
            let _ = SetForegroundWindow(parent.0);
            SetLastError(WIN32_ERROR(0));
            if let Err(error) = SetFocus(Some(edit))
                && GetLastError().0 != 0
            {
                api("SetFocus", Err::<(), _>(error), true)?;
            }
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
                let result = super::with_input_desktop(acquire_input_desktop, |_| {
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
                        let result = WindowsInjector.insert_text(SAMPLE).map_err(|e| {
                            e.context("WindowsInjector::insert_text (UIA/clipboard/SendInput)")
                        });
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
                        let len = read_edit(edit, &mut text)?;
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
                });
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
                let len = read_edit(edit, &mut text)?;
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
            if let Some(reason) = result? {
                println!("SKIPPED: worker {reason}");
                return Ok(());
            }
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
