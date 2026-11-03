use crate::policy::{self, FocusEvidence};
use std::mem::size_of;
use voiceremote_core::{Result, ensure};
use windows::Win32::{
    Foundation::{CloseHandle, HANDLE, HWND},
    Security::{
        GetSidSubAuthority, GetSidSubAuthorityCount, GetTokenInformation, IsValidSid,
        TOKEN_MANDATORY_LABEL, TOKEN_QUERY, TokenIntegrityLevel,
    },
    System::{
        Com::{
            CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx,
            CoUninitialize,
        },
        SystemInformation::GetTickCount,
        Threading::{
            GetCurrentProcess, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION,
        },
        Variant::VT_BOOL,
    },
    UI::{
        Accessibility::*,
        Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO},
        WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId},
    },
};

struct Apartment;
impl Apartment {
    fn new() -> Result<Self> {
        // Every caller runs on a fresh dedicated thread, never Tokio's threads.
        unsafe {
            CoInitializeEx(None, COINIT_MULTITHREADED).ok()?;
        }
        Ok(Self)
    }
}
impl Drop for Apartment {
    fn drop(&mut self) {
        unsafe {
            CoUninitialize();
        }
    }
}
struct Handle(HANDLE);
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}

fn integrity(process: HANDLE) -> Result<u32> {
    unsafe {
        let mut token = HANDLE::default();
        OpenProcessToken(process, TOKEN_QUERY, &mut token)?;
        let token = Handle(token);
        // Aligned storage, comfortably larger than TOKEN_MANDATORY_LABEL + SID.
        let mut storage = [0u64; 128];
        let mut used = 0;
        GetTokenInformation(
            token.0,
            TokenIntegrityLevel,
            Some(storage.as_mut_ptr().cast()),
            size_of_val(&storage) as u32,
            &mut used,
        )?;
        let label = &*storage.as_ptr().cast::<TOKEN_MANDATORY_LABEL>();
        ensure!(
            IsValidSid(label.Label.Sid).as_bool(),
            "invalid target integrity SID"
        );
        let count = *GetSidSubAuthorityCount(label.Label.Sid);
        ensure!(count > 0, "missing target integrity level");
        Ok(*GetSidSubAuthority(label.Label.Sid, u32::from(count - 1)))
    }
}
fn require_integrity(hwnd: HWND) -> Result<()> {
    unsafe {
        let mut pid = 0;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        ensure!(pid != 0, "no foreground target process");
        let target = Handle(
            OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).map_err(|_| {
                voiceremote_core::anyhow!(
                    "cannot inspect target privileges; elevated/UIPI target unavailable"
                )
            })?,
        );
        ensure!(
            integrity(target.0)? <= integrity(GetCurrentProcess())?,
            "elevated target blocked by UIPI; focus an app at the receiver's privilege level"
        );
    }
    Ok(())
}

fn is_editable(element: &IUIAutomationElement) -> bool {
    // Do not ask for name, value, text, selection contents, or password text.
    unsafe {
        let password = element.CurrentIsPassword().ok().map(|v| v.as_bool());
        if password != Some(false) {
            return false;
        }
        let editable = if let Ok(value) =
            element.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
        {
            value.CurrentIsReadOnly().ok().map(|v| !v.as_bool())
        } else if let Ok(text) =
            element.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId)
        {
            // A read-only attribute is metadata. Never call GetText / CurrentValue.
            text.DocumentRange()
                .and_then(|r| r.GetAttributeValue(UIA_IsReadOnlyAttributeId))
                .ok()
                .and_then(|v| {
                    (v.vt() == VT_BOOL).then(|| !v.Anonymous.Anonymous.Anonymous.boolVal.as_bool())
                })
        } else {
            None
        };
        policy::editable_focus(FocusEvidence {
            focused: element.CurrentHasKeyboardFocus().is_ok_and(|v| v.as_bool()),
            enabled: element.CurrentIsEnabled().is_ok_and(|v| v.as_bool()),
            password,
            editable,
        })
    }
}

pub(super) struct Target {
    automation: IUIAutomation,
    element: IUIAutomationElement,
    foreground: HWND,
    // Drop COM interfaces before uninitializing their apartment.
    _apartment: Apartment,
}
impl Target {
    pub(super) fn capture() -> Result<Self> {
        let apartment = Apartment::new()?;
        unsafe {
            let foreground = GetForegroundWindow();
            ensure!(!foreground.is_invalid(), "no foreground target window");
            require_integrity(foreground)?;
            let automation: IUIAutomation =
                CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)?;
            let element = automation.GetFocusedElement()?;
            ensure!(
                is_editable(&element),
                "no focused editable non-password control"
            );
            // Walk only ancestry metadata: cross-process Chromium descendants
            // need not have the foreground window's PID or a native HWND.
            let root = automation.ElementFromHandle(foreground)?;
            let walker = automation.RawViewWalker()?;
            let mut ancestor = element.clone();
            let mut belongs = false;
            for _ in 0..64 {
                if automation.CompareElements(&ancestor, &root)?.as_bool() {
                    belongs = true;
                    break;
                }
                ancestor = walker.GetParentElement(&ancestor)?;
            }
            ensure!(
                belongs && GetForegroundWindow() == foreground,
                "focus changed during target inspection"
            );
            Ok(Self {
                automation,
                element,
                foreground,
                _apartment: apartment,
            })
        }
    }
    pub(super) fn require_unchanged(&self) -> Result<()> {
        unsafe {
            ensure!(
                GetForegroundWindow() == self.foreground,
                "foreground target changed; retry dictation"
            );
            require_integrity(self.foreground)?;
            let current = self.automation.GetFocusedElement()?;
            ensure!(
                self.automation
                    .CompareElements(&current, &self.element)?
                    .as_bool()
                    && is_editable(&current),
                "editable focus changed or became protected; retry dictation"
            );
        }
        Ok(())
    }
}

pub(super) fn activity_age() -> Option<u64> {
    let mut info = LASTINPUTINFO {
        cbSize: size_of::<LASTINPUTINFO>() as u32,
        ..Default::default()
    };
    unsafe {
        if !GetLastInputInfo(&mut info).as_bool() {
            return None;
        }
        Some(u64::from(GetTickCount().wrapping_sub(info.dwTime)))
    }
}
