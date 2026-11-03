//! Owner-controlled file reads use the concrete token user SID, as the tray pipe
//! DACL does. Reject null ACLs, foreign writers, reparse points and unknown ACEs.
use anyhow::{Result, ensure};
use std::{
    fs::OpenOptions,
    io::Read,
    os::windows::{
        fs::{MetadataExt, OpenOptionsExt},
        io::AsRawHandle,
    },
    path::Path,
    ptr::null_mut,
};
use windows_sys::Win32::{
    Foundation::{CloseHandle, LocalFree},
    Security::{
        ACCESS_ALLOWED_ACE, ACE_HEADER,
        Authorization::{GetSecurityInfo, SE_FILE_OBJECT},
        DACL_SECURITY_INFORMATION, EqualSid, GetAce, GetTokenInformation,
        OWNER_SECURITY_INFORMATION, TOKEN_QUERY, TOKEN_USER, TokenUser,
    },
    System::Threading::{GetCurrentProcess, OpenProcessToken},
};

pub(crate) fn read(path: &Path, limit: u64) -> Result<String> {
    // Hold one read handle, refusing concurrent writes/deletion; ACL validation
    // and bytes refer to the same object even if its pathname is replaced.
    let file = OpenOptions::new()
        .read(true)
        .share_mode(1)
        .custom_flags(0x00200000)
        .open(path)?; // FILE_FLAG_OPEN_REPARSE_POINT
    let meta = file.metadata()?;
    ensure!(
        meta.is_file() && meta.file_attributes() & 0x400 == 0 && meta.len() <= limit,
        "unsafe owner file"
    );
    unsafe {
        let mut token = null_mut();
        ensure!(
            OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) != 0,
            "cannot query owner"
        );
        let checked = (|| -> Result<()> {
            let mut size = 0;
            GetTokenInformation(token, TokenUser, null_mut(), 0, &mut size);
            ensure!(size > 0, "missing token user");
            let mut buffer = vec![0usize; (size as usize).div_ceil(size_of::<usize>())];
            ensure!(
                GetTokenInformation(
                    token,
                    TokenUser,
                    buffer.as_mut_ptr().cast(),
                    size,
                    &mut size
                ) != 0,
                "cannot read owner"
            );
            let user = &*(buffer.as_ptr().cast::<TOKEN_USER>());
            let mut owner = null_mut();
            let mut dacl = null_mut();
            let mut descriptor = null_mut();
            ensure!(
                GetSecurityInfo(
                    file.as_raw_handle(),
                    SE_FILE_OBJECT,
                    OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                    &mut owner,
                    null_mut(),
                    &mut dacl,
                    null_mut(),
                    &mut descriptor
                ) == 0,
                "cannot inspect owner ACL"
            );
            let result = (|| -> Result<()> {
                ensure!(
                    !owner.is_null() && EqualSid(owner, user.User.Sid) != 0,
                    "foreign file owner"
                );
                ensure!(!dacl.is_null(), "unrestricted file ACL");
                for index in 0..(*dacl).AceCount as u32 {
                    let mut raw = null_mut();
                    ensure!(GetAce(dacl, index, &mut raw) != 0, "cannot inspect ACE");
                    let header = &*(raw.cast::<ACE_HEADER>());
                    if header.AceFlags & 8 != 0 {
                        continue;
                    } // INHERIT_ONLY_ACE
                    match header.AceType {
                        0 => {
                            let ace = &*(raw.cast::<ACCESS_ALLOWED_ACE>());
                            // Write/append/EA/attributes, delete/change ACL/owner,
                            // GENERIC_WRITE/ALL and MAXIMUM_ALLOWED all confer authority.
                            let writes = 0x000D_0116 | 0x5000_0000 | 0x0200_0000;
                            ensure!(
                                ace.Mask & writes == 0
                                    || EqualSid(
                                        (&ace.SidStart as *const u32).cast_mut().cast(),
                                        user.User.Sid
                                    ) != 0,
                                "file grants another principal write authority"
                            );
                        }
                        1 => {} // A deny cannot expand authority.
                        _ => anyhow::bail!("unsupported file ACE"),
                    }
                }
                Ok(())
            })();
            LocalFree(descriptor);
            result
        })();
        CloseHandle(token);
        checked?;
    }
    let mut text = String::new();
    file.take(limit + 1).read_to_string(&mut text)?;
    ensure!(text.len() as u64 <= limit, "owner file grew");
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows_sys::Win32::Security::{
        Authorization::{
            ConvertStringSecurityDescriptorToSecurityDescriptorW, SetNamedSecurityInfoW,
        },
        GetSecurityDescriptorControl, GetSecurityDescriptorDacl, GetSecurityDescriptorOwner,
        PROTECTED_DACL_SECURITY_INFORMATION, SE_DACL_PROTECTED,
        UNPROTECTED_DACL_SECURITY_INFORMATION,
    };
    // SDDL's owner and inheritance flags are part of the fixture contract.
    // Setting only DACL_SECURITY_INFORMATION leaves TokenOwner unchanged,
    // which can be BUILTIN\Administrators on an elevated Windows runner.
    fn security(path: &Path, sddl: &str) -> Result<()> {
        use std::os::windows::ffi::OsStrExt;
        let mut name: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
        let sddl: Vec<u16> = sddl.encode_utf16().chain(Some(0)).collect();
        unsafe {
            let mut descriptor = null_mut();
            ensure!(
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    sddl.as_ptr(),
                    1,
                    &mut descriptor,
                    null_mut()
                ) != 0,
                "test descriptor"
            );
            let mut present = 0;
            let mut defaulted = 0;
            let mut dacl = null_mut();
            let mut owner = null_mut();
            let mut owner_defaulted = 0;
            let mut control = 0;
            let mut revision = 0;
            let parsed =
                GetSecurityDescriptorDacl(descriptor, &mut present, &mut dacl, &mut defaulted) != 0
                    && GetSecurityDescriptorOwner(descriptor, &mut owner, &mut owner_defaulted)
                        != 0
                    && GetSecurityDescriptorControl(descriptor, &mut control, &mut revision) != 0;
            if !parsed || present == 0 {
                LocalFree(descriptor);
                anyhow::bail!("test descriptor must contain a DACL");
            }
            let flags = DACL_SECURITY_INFORMATION
                // Isolate the null-DACL probe from parent inheritance.
                | if control & SE_DACL_PROTECTED != 0 || dacl.is_null() {
                    PROTECTED_DACL_SECURITY_INFORMATION
                } else {
                    UNPROTECTED_DACL_SECURITY_INFORMATION
                }
                | if owner.is_null() {
                    0
                } else {
                    OWNER_SECURITY_INFORMATION
                };
            let status = SetNamedSecurityInfoW(
                name.as_mut_ptr(),
                SE_FILE_OBJECT,
                flags,
                owner,
                null_mut(),
                dacl,
                null_mut(),
            );
            LocalFree(descriptor);
            ensure!(
                status == 0,
                "setting test owner/DACL failed (Win32 {status})"
            );
        }
        Ok(())
    }
    fn file_security(path: &Path) -> Result<(String, bool, bool)> {
        let file = OpenOptions::new().read(true).open(path)?;
        unsafe {
            let mut owner = null_mut();
            let mut dacl = null_mut();
            let mut descriptor = null_mut();
            ensure!(
                GetSecurityInfo(
                    file.as_raw_handle(),
                    SE_FILE_OBJECT,
                    OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                    &mut owner,
                    null_mut(),
                    &mut dacl,
                    null_mut(),
                    &mut descriptor
                ) == 0,
                "reading fixture security"
            );
            let result = (|| -> Result<_> {
                let owner = sid_text(owner)?;
                let mut control = 0;
                let mut revision = 0;
                ensure!(
                    GetSecurityDescriptorControl(descriptor, &mut control, &mut revision) != 0,
                    "reading fixture control flags"
                );
                let mut inherited = false;
                if !dacl.is_null() {
                    for index in 0..(*dacl).AceCount as u32 {
                        let mut raw = null_mut();
                        ensure!(GetAce(dacl, index, &mut raw) != 0, "reading fixture ACE");
                        inherited |= (*(raw.cast::<ACE_HEADER>())).AceFlags & 0x10 != 0;
                    }
                }
                Ok((owner, control & SE_DACL_PROTECTED != 0, inherited))
            })();
            LocalFree(descriptor);
            result
        }
    }
    unsafe fn sid_text(sid: windows_sys::Win32::Security::PSID) -> Result<String> {
        use windows_sys::Win32::Security::Authorization::ConvertSidToStringSidW;
        unsafe {
            let mut text = null_mut();
            ensure!(
                !sid.is_null() && ConvertSidToStringSidW(sid, &mut text) != 0,
                "test SID"
            );
            let mut length = 0;
            while *text.add(length) != 0 {
                length += 1;
            }
            let value = String::from_utf16_lossy(std::slice::from_raw_parts(text, length));
            LocalFree(text.cast());
            Ok(value)
        }
    }
    fn current_sid() -> Result<String> {
        unsafe {
            let mut token = null_mut();
            ensure!(
                OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) != 0,
                "test token"
            );
            let mut size = 0;
            GetTokenInformation(token, TokenUser, null_mut(), 0, &mut size);
            let mut buffer = vec![0usize; (size as usize).div_ceil(size_of::<usize>())];
            let ok = GetTokenInformation(
                token,
                TokenUser,
                buffer.as_mut_ptr().cast(),
                size,
                &mut size,
            );
            CloseHandle(token);
            ensure!(ok != 0, "test user");
            sid_text((*(buffer.as_ptr().cast::<TOKEN_USER>())).User.Sid)
        }
    }
    #[test]
    fn owner_file_rejects_everyone_write_and_null_dacl() -> Result<()> {
        let root = tempfile::tempdir()?;
        let file = root.path().join("agents.toml");
        std::fs::write(
            &file,
            "account='synthetic'\nhost='pc'\nphone_device='phone'\nactor='owner'\nprojects=[]",
        )?;
        let sid = current_sid()?;
        // Reproduce the old fixture: DACL-only setup does not change its owner.
        let original_owner = file_security(&file)?.0;
        security(&file, &format!("D:P(A;;FA;;;{sid})"))?;
        assert_eq!(file_security(&file)?.0, original_owner);
        if original_owner != sid {
            assert_eq!(
                read(&file, 1024).unwrap_err().to_string(),
                "foreign file owner"
            );
        }
        security(&file, &format!("O:{sid}D:P(A;;FA;;;{sid})"))?;
        assert_eq!(file_security(&file)?, (sid.clone(), true, false));
        crate::Allowlist::load(&file)?; // Keep the actual production error in CI output.
        read(&file, 1024)?;
        security(&file, &format!("D:P(A;;FA;;;{sid})(A;;FA;;;WD)"))?;
        assert!(crate::Allowlist::load(&file).is_err());
        assert_eq!(
            read(&file, 1024).unwrap_err().to_string(),
            "file grants another principal write authority"
        );
        security(&file, "D:NO_ACCESS_CONTROL")?;
        assert_eq!(
            read(&file, 1024).unwrap_err().to_string(),
            "unrestricted file ACL"
        );
        security(&file, "D:P(A;;FA;;;OW)")?;
        // Owner Rights is intentionally not a concrete user SID: fail closed.
        assert_eq!(
            read(&file, 1024).unwrap_err().to_string(),
            "file grants another principal write authority"
        );
        Ok(())
    }

    #[test]
    fn inherited_world_write_is_rejected_until_dacl_is_protected() -> Result<()> {
        let root = tempfile::tempdir()?;
        let sid = current_sid()?;
        security(
            root.path(),
            &format!("O:{sid}D:P(A;OICI;FA;;;{sid})(A;OICI;FA;;;WD)"),
        )?;
        let file = root.path().join("discovery.toml");
        std::fs::write(&file, "sessions=[]")?;
        // Set the concrete owner but leave inheritance enabled: parent Everyone
        // write must still be refused, even with an explicit current-user ACE.
        security(&file, &format!("O:{sid}D:(A;;FA;;;{sid})"))?;
        assert_eq!(file_security(&file)?, (sid.clone(), false, true));
        assert_eq!(
            read(&file, 1024).unwrap_err().to_string(),
            "file grants another principal write authority"
        );
        security(&file, &format!("O:{sid}D:P(A;;FA;;;{sid})"))?;
        assert_eq!(file_security(&file)?, (sid, true, false));
        assert_eq!(read(&file, 1024)?, "sessions=[]");
        Ok(())
    }
}
