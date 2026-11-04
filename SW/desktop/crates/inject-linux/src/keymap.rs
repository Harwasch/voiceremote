//! Parse compositor-provided XKB maps. Dynamic libxkbcommon, no link-time dependency.
use anyhow::{Result, ensure};
use xkbcommon_dl::*;
pub(crate) struct Keymap {
    keys: std::collections::HashMap<(u32, u32), u32>,
}
impl Keymap {
    pub(crate) fn parse(bytes: &[u8]) -> Result<Self> {
        let api = xkbcommon_option().ok_or_else(|| anyhow::anyhow!("libxkbcommon unavailable"))?;
        // All pointers below are owned XKB objects; the input buffer is valid for
        // the synchronous parser call and XKB owns the compiled result.
        unsafe {
            let context = (api.xkb_context_new)(xkb_context_flags::XKB_CONTEXT_NO_FLAGS);
            ensure!(!context.is_null(), "XKB context unavailable");
            (api.xkb_context_set_log_level)(context, xkb_log_level::XKB_LOG_LEVEL_CRITICAL);
            let bytes = bytes.strip_suffix(&[0]).unwrap_or(bytes);
            let map = (api.xkb_keymap_new_from_buffer)(
                context,
                bytes.as_ptr().cast(),
                bytes.len(),
                xkb_keymap_format::XKB_KEYMAP_FORMAT_TEXT_V1,
                xkb_keymap_compile_flags::XKB_KEYMAP_COMPILE_NO_FLAGS,
            );
            (api.xkb_context_unref)(context);
            ensure!(!map.is_null(), "invalid compositor keymap");
            let mut keys = std::collections::HashMap::new();
            let groups = (api.xkb_keymap_num_layouts)(map).min(64);
            for group in 0..groups {
                for key in (api.xkb_keymap_min_keycode)(map)..=(api.xkb_keymap_max_keycode)(map) {
                    if key < 8 || [15, 28, 96].contains(&(key - 8)) {
                        continue;
                    }
                    let mut syms = std::ptr::null();
                    let n = (api.xkb_keymap_key_get_syms_by_level)(map, key, group, 0, &mut syms);
                    if n == 1 && [0xffe3, 0xffe1, b'v' as u32].contains(&*syms) {
                        keys.entry((*syms, group)).or_insert(key - 8);
                    }
                }
            }
            (api.xkb_keymap_unref)(map);
            Ok(Self { keys })
        }
    }
    pub(crate) fn key(&self, sym: u32, group: u32) -> Option<u32> {
        self.keys.get(&(sym, group)).copied()
    }
    pub(crate) fn paste(&self, terminal: bool, group: u32) -> Option<Vec<u32>> {
        let mut keys = vec![self.key(0xffe3, group)?];
        if terminal {
            keys.push(self.key(0xffe1, group)?);
        }
        keys.push(self.key(b'v' as u32, group)?);
        Some(keys)
    }
}
#[cfg(test)]
pub(crate) fn fixture(variant: &str) -> Vec<u8> {
    use std::ffi::{CStr, CString};
    let api = xkbcommon_option().expect("test needs libxkbcommon runtime");
    let variant = CString::new(variant).unwrap();
    unsafe {
        let context = (api.xkb_context_new)(xkb_context_flags::XKB_CONTEXT_NO_FLAGS);
        let names = xkb_rule_names {
            rules: std::ptr::null(),
            model: std::ptr::null(),
            layout: c"us".as_ptr(),
            variant: variant.as_ptr(),
            options: c"".as_ptr(),
        };
        let map = (api.xkb_keymap_new_from_names)(
            context,
            &names,
            xkb_keymap_compile_flags::XKB_KEYMAP_COMPILE_NO_FLAGS,
        );
        assert!(!map.is_null());
        let text =
            (api.xkb_keymap_get_as_string)(map, xkb_keymap_format::XKB_KEYMAP_FORMAT_TEXT_V1);
        let bytes = CStr::from_ptr(text).to_bytes_with_nul().to_vec();
        libc::free(text.cast_mut().cast());
        (api.xkb_keymap_unref)(map);
        (api.xkb_context_unref)(context);
        bytes
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dvorak_paste_uses_v_from_the_advertised_layout() {
        let us = Keymap::parse(&fixture("")).unwrap();
        let dvorak = Keymap::parse(&fixture("dvorak")).unwrap();
        assert_eq!(us.key(b'v' as u32, 0), Some(47));
        assert_ne!(dvorak.key(b'v' as u32, 0), Some(47));
        assert_eq!(dvorak.paste(true, 0).unwrap().len(), 3);
    }
}
