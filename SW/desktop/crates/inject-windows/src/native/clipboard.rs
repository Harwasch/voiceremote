// Clipboard allocation, snapshot, delayed rendering and privacy markers adapted
// from cjpais/Handy src-tauri/src/paste_tx/windows.rs (MIT).
// Copyright (c) 2025 CJ Pais
// Ownership guard also follows anomalyco/hex src/windows/paste.rs (MIT).
// Copyright (c) 2026 Christopher Langton
// Full permission notices: DOCS/licences/{Handy,hex}-MIT.txt.
use super::{focus::Target, input};
use crate::policy::{self, PasteAttempt};
use std::{
    cell::{Cell, RefCell},
    mem::size_of,
    sync::OnceLock,
    thread,
    time::{Duration, Instant},
};
use voiceremote_core::{Result, anyhow, ensure};
use windows::{
    Win32::{
        Foundation::{
            ERROR_SUCCESS, GetLastError, GlobalFree, HANDLE, HGLOBAL, HINSTANCE, HWND, LPARAM,
            LRESULT, SetLastError, WPARAM,
        },
        System::{
            DataExchange::*,
            LibraryLoader::GetModuleHandleW,
            Memory::{GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock},
            Ole::CF_UNICODETEXT,
        },
        UI::WindowsAndMessaging::*,
    },
    core::{PCWSTR, w},
};

const MAX_SNAPSHOT_BYTES: usize = 64 * 1024 * 1024;
const SETTLE: Duration = Duration::from_millis(150);
const RECEIPT_TIMEOUT: Duration = Duration::from_millis(750);

struct Global(Option<HGLOBAL>);
impl Global {
    fn copy(bytes: &[u8]) -> Result<Self> {
        unsafe {
            let memory = Self(Some(GlobalAlloc(GMEM_MOVEABLE, bytes.len())?));
            let ptr = GlobalLock(memory.0.unwrap());
            ensure!(!ptr.is_null(), "clipboard allocation could not be locked");
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr.cast(), bytes.len());
            let _ = GlobalUnlock(memory.0.unwrap());
            Ok(memory)
        }
    }
    fn publish(&mut self, format: u32) -> Result<()> {
        unsafe {
            SetClipboardData(format, Some(HANDLE(self.0.unwrap().0)))?;
        }
        self.0 = None; // Windows owns it only after SetClipboardData succeeds.
        Ok(())
    }
}
impl Drop for Global {
    fn drop(&mut self) {
        if let Some(memory) = self.0.take() {
            unsafe {
                let _ = GlobalFree(Some(memory));
            }
        }
    }
}
struct Open;
impl Open {
    fn new(hwnd: HWND) -> Result<Self> {
        unsafe {
            OpenClipboard(Some(hwnd))?;
        }
        Ok(Self)
    }
}
impl Drop for Open {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseClipboard();
        }
    }
}

struct Saved {
    format: u32,
    memory: Global,
}
fn snapshot() -> Result<Vec<Saved>> {
    let mut result = Vec::new();
    let mut format = 0;
    let mut total = 0;
    unsafe {
        loop {
            SetLastError(ERROR_SUCCESS);
            format = EnumClipboardFormats(format);
            if format == 0 {
                ensure!(
                    GetLastError() == ERROR_SUCCESS,
                    "cannot enumerate previous clipboard"
                );
                break;
            }
            // These standard formats use HGLOBAL. GDI/metafile, owner-display,
            // and private handle formats cannot be byte-copied. Refuse to
            // overwrite them; Unicode fallback leaves them completely intact.
            ensure!(
                matches!(format, 1 | 4..=8 | 13 | 15..=17 | 0xc000..=0xffff),
                "previous clipboard has a format that cannot be restored safely"
            );
            let data = GetClipboardData(format)?;
            let memory = HGLOBAL(data.0);
            let size = GlobalSize(memory);
            total += size;
            ensure!(
                size > 0 && total <= MAX_SNAPSHOT_BYTES,
                "previous clipboard cannot be safely snapshotted"
            );
            let ptr = GlobalLock(memory);
            ensure!(!ptr.is_null(), "previous clipboard cannot be locked");
            let copy = Global::copy(std::slice::from_raw_parts(ptr.cast::<u8>(), size));
            let _ = GlobalUnlock(memory);
            result.push(Saved {
                format,
                memory: copy?,
            });
        }
    }
    Ok(result)
}

struct RenderState {
    text: RefCell<Global>,
    rendered: Cell<bool>,
    failed: Cell<bool>,
    sequence: Cell<u32>,
}
unsafe extern "system" fn window_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    // The boxed state outlives the hidden window, and all access is on its
    // owning thread. No Rust borrow is held while DispatchMessage calls us.
    unsafe {
        if msg == WM_RENDERFORMAT && wp.0 == CF_UNICODETEXT.0 as usize {
            let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *const RenderState;
            if let Some(state) = ptr.as_ref()
                && !state.rendered.get()
            {
                let rendered = state
                    .text
                    .borrow_mut()
                    .publish(CF_UNICODETEXT.0 as u32)
                    .is_ok();
                state.rendered.set(rendered);
                state.failed.set(!rendered);
                state.sequence.set(GetClipboardSequenceNumber());
            }
            return LRESULT(0);
        }
        DefWindowProcW(hwnd, msg, wp, lp)
    }
}
struct Window(HWND);
impl Window {
    fn new(state: &RenderState) -> Result<Self> {
        static CLASS: OnceLock<u16> = OnceLock::new();
        unsafe {
            let module = HINSTANCE(GetModuleHandleW(None)?.0);
            let class = *CLASS.get_or_init(|| {
                RegisterClassW(&WNDCLASSW {
                    lpfnWndProc: Some(window_proc),
                    hInstance: module,
                    lpszClassName: w!("VoiceRemoteClipboardTransaction"),
                    ..Default::default()
                })
            });
            ensure!(class != 0, "cannot register clipboard owner window");
            let hwnd = CreateWindowExW(
                WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                w!("VoiceRemoteClipboardTransaction"),
                w!(""),
                WINDOW_STYLE(0),
                0,
                0,
                0,
                0,
                Some(HWND_MESSAGE),
                None,
                Some(module),
                None,
            )?;
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, state as *const RenderState as isize);
            Ok(Self(hwnd))
        }
    }
}
impl Drop for Window {
    fn drop(&mut self) {
        unsafe {
            let _ = DestroyWindow(self.0);
        }
    }
}

fn pump() {
    unsafe {
        let mut message = MSG::default();
        while PeekMessageW(&mut message, None, 0, 0, PM_REMOVE).as_bool() {
            DispatchMessageW(&message);
        }
    }
}
fn privacy_markers() -> Result<Vec<Saved>> {
    [
        ("ExcludeClipboardContentFromMonitorProcessing", 1u32),
        ("CanIncludeInClipboardHistory", 0u32),
        ("CanUploadToCloudClipboard", 0u32),
    ]
    .into_iter()
    .map(|(name, value)| {
        let name: Vec<_> = name.encode_utf16().chain([0]).collect();
        let format = unsafe { RegisterClipboardFormatW(PCWSTR(name.as_ptr())) };
        ensure!(format != 0, "cannot register clipboard privacy marker");
        Ok(Saved {
            format,
            memory: Global::copy(&value.to_ne_bytes())?,
        })
    })
    .collect()
}

struct Transaction {
    // Window must be destroyed before its userdata storage.
    window: Window,
    state: Box<RenderState>,
    saved: Vec<Saved>,
    dirty: bool,
}
impl Transaction {
    fn prepare(text: &str) -> Result<Self> {
        let wide: Vec<u16> = text.encode_utf16().chain([0]).collect();
        let bytes = unsafe {
            std::slice::from_raw_parts(wide.as_ptr().cast::<u8>(), wide.len() * size_of::<u16>())
        };
        let state = Box::new(RenderState {
            text: RefCell::new(Global::copy(bytes)?),
            rendered: Cell::new(false),
            failed: Cell::new(false),
            sequence: Cell::new(0),
        });
        let window = Window::new(&state)?;
        Ok(Self {
            window,
            state,
            saved: Vec::new(),
            dirty: false,
        })
    }
    fn publish(&mut self) -> Result<()> {
        let mut markers = privacy_markers()?;
        let _open = Open::new(self.window.0)?;
        self.saved = snapshot()?;
        unsafe {
            EmptyClipboard()?;
            self.dirty = true;
            // Capture the sequence even if a later publication fails.
            let result = (|| -> Result<()> {
                for marker in &mut markers {
                    marker.memory.publish(marker.format)?;
                }
                // A NULL handle advertises delayed rendering, so a successful
                // call can return NULL. Only a nonzero last error is failure.
                SetLastError(ERROR_SUCCESS);
                let _ = SetClipboardData(CF_UNICODETEXT.0 as u32, None);
                ensure!(
                    GetLastError() == ERROR_SUCCESS,
                    "cannot advertise clipboard text"
                );
                Ok(())
            })();
            self.state.sequence.set(GetClipboardSequenceNumber());
            result
        }
    }
    fn restore(&mut self) -> Result<()> {
        if !self.dirty {
            return Ok(());
        }
        // Retry lock contention; check owner+sequence *inside* the open lock.
        let deadline = Instant::now() + Duration::from_secs(2);
        let _open = loop {
            match Open::new(self.window.0) {
                Ok(open) => break open,
                Err(_) if Instant::now() < deadline => {
                    pump();
                    thread::sleep(Duration::from_millis(10));
                }
                Err(_) => return Err(anyhow!("clipboard restore blocked; delivery uncertain")),
            }
        };
        unsafe {
            let ours = GetClipboardOwner().is_ok_and(|owner| owner == self.window.0);
            if !policy::may_restore(
                self.state.sequence.get(),
                GetClipboardSequenceNumber(),
                ours,
                self.state.rendered.get(),
            ) {
                self.dirty = false; // A new user copy belongs to the user.
                return Ok(());
            }
            EmptyClipboard()?;
            // All allocations were made before publication, while the old
            // clipboard still existed. No allocation is needed for restore.
            let mut failed = false;
            for saved in &mut self.saved {
                failed |= saved.memory.publish(saved.format).is_err();
            }
            self.dirty = false;
            ensure!(!failed, "clipboard restore incomplete; delivery uncertain");
        }
        Ok(())
    }
}
impl Drop for Transaction {
    fn drop(&mut self) {
        let _ = self.restore();
    }
}

pub(super) fn paste(target: &Target, text: &str) -> PasteAttempt {
    let Ok(mut tx) = Transaction::prepare(text) else {
        return PasteAttempt::Unavailable;
    };
    if tx.publish().is_err() {
        // If publication mutated anything, restoration must succeed before
        // fallback is allowed. Never silently leave dictated text behind.
        return match tx.restore() {
            Ok(()) => PasteAttempt::Unavailable,
            Err(error) => PasteAttempt::Finished(Err(error)),
        };
    }
    let result = (|| -> Result<()> {
        thread::sleep(Duration::from_millis(50));
        target.require_unchanged()?;
        input::require_no_modifiers()?;
        // If the clipboard changed before the chord, do not paste user data.
        unsafe {
            ensure!(
                policy::may_restore(
                    tx.state.sequence.get(),
                    GetClipboardSequenceNumber(),
                    GetClipboardOwner().is_ok_and(|owner| owner == tx.window.0),
                    tx.state.rendered.get(),
                ),
                "clipboard changed before paste; insertion cancelled"
            );
        }
        input::send(&policy::paste_events())?;
        let deadline = Instant::now() + RECEIPT_TIMEOUT;
        let mut received_at = None;
        loop {
            pump();
            ensure!(
                !tx.state.failed.get(),
                "clipboard text could not be rendered"
            );
            if tx.state.rendered.get() && received_at.is_none() {
                received_at = Some(Instant::now());
            }
            if received_at.is_some_and(|time| Instant::now().duration_since(time) >= SETTLE) {
                break;
            }
            ensure!(
                Instant::now() < deadline,
                "paste not confirmed by a clipboard read; delivery uncertain, do not retry automatically"
            );
            thread::sleep(Duration::from_millis(5));
        }
        Ok(())
    })();
    // Restore even after SendInput, focus checks, or receipt polling fail.
    let restored = tx.restore();
    PasteAttempt::Finished(restored.and(result))
}
