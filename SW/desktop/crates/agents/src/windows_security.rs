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
        GetSecurityDescriptorDacl, PROTECTED_DACL_SECURITY_INFORMATION,
    };
    fn acl(path: &Path, sddl: &str) -> Result<()> {
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
            let found =
                GetSecurityDescriptorDacl(descriptor, &mut present, &mut dacl, &mut defaulted);
            let status = SetNamedSecurityInfoW(
                name.as_mut_ptr(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                null_mut(),
                null_mut(),
                dacl,
                null_mut(),
            );
            LocalFree(descriptor);
            ensure!(found != 0 && present != 0 && status == 0, "test file ACL");
        }
        Ok(())
    }
    fn current_sid() -> Result<String> {
        use windows_sys::Win32::Security::Authorization::ConvertSidToStringSidW;
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
            let mut text = null_mut();
            ensure!(
                ConvertSidToStringSidW(
                    (*(buffer.as_ptr().cast::<TOKEN_USER>())).User.Sid,
                    &mut text
                ) != 0,
                "test SID"
            );
            let mut length = 0;
            while *text.add(length) != 0 {
                length += 1;
            }
            let sid = String::from_utf16_lossy(std::slice::from_raw_parts(text, length));
            LocalFree(text.cast());
            Ok(sid)
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
        acl(&file, &format!("D:P(A;;FA;;;{sid})"))?;
        assert!(crate::Allowlist::load(&file).is_ok());
        assert!(read(&file, 1024).is_ok());
        acl(&file, &format!("D:P(A;;FA;;;{sid})(A;;FA;;;WD)"))?;
        assert!(crate::Allowlist::load(&file).is_err());
        assert!(read(&file, 1024).is_err()); // discovery reads use this same boundary
        acl(&file, "D:NO_ACCESS_CONTROL")?;
        assert!(read(&file, 1024).is_err());
        acl(&file, "D:P(A;;FA;;;OW)")?;
        // Owner Rights is intentionally not a concrete user SID: fail closed.
        assert!(read(&file, 1024).is_err());
        Ok(())
    }
}
