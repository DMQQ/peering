//! DPAPI sealing for the current user, through CryptProtectData and CryptUnprotectData.

use std::ffi::c_void;
use std::io;
use std::path::Path;
use std::ptr::null_mut;

use windows::core::PCWSTR;
use zeroize::Zeroize;
use windows::Win32::Foundation::{LocalFree, HLOCAL};
use windows::Win32::Security::Cryptography::{
    CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
};

use crate::dpapi::{acl, Protector};

/// Mixed into every seal, so a process of the same user that calls `CryptUnprotectData` on a copy of a secret file
/// without this value gets nothing. It is not a secret from code that reads this source.
const ENTROPY: &[u8] = b"pl.dmq.peering.host secret store v1";

/// Seals for the logged-on user only. The UI flag stops DPAPI from ever opening a prompt on the secure desktop.
#[derive(Debug, Clone, Copy, Default)]
pub struct DpapiProtector;

impl Protector for DpapiProtector {
    fn protect(&self, plain: &[u8]) -> Option<Vec<u8>> {
        transform(plain, Direction::Protect, Some(ENTROPY))
    }

    fn unprotect(&self, sealed: &[u8]) -> Option<Vec<u8>> {
        // A file sealed before the entropy was added still opens, and is sealed with it on its next write.
        transform(sealed, Direction::Unprotect, Some(ENTROPY)).or_else(|| transform(sealed, Direction::Unprotect, None))
    }

    fn prepare_directory(&self, directory: &Path) -> io::Result<()> {
        acl::restrict_to_owner(directory)
    }
}

#[derive(Clone, Copy)]
enum Direction {
    Protect,
    Unprotect,
}

fn transform(input: &[u8], direction: Direction, entropy: Option<&[u8]>) -> Option<Vec<u8>> {
    let length = u32::try_from(input.len()).ok()?;
    let in_blob = CRYPT_INTEGER_BLOB { cbData: length, pbData: input.as_ptr() as *mut u8 };
    let entropy_blob = entropy.map(|bytes| CRYPT_INTEGER_BLOB { cbData: bytes.len() as u32, pbData: bytes.as_ptr() as *mut u8 });
    let entropy_pointer = entropy_blob.as_ref().map(std::ptr::from_ref);
    let mut out_blob = CRYPT_INTEGER_BLOB { cbData: 0, pbData: null_mut() };
    // SAFETY: `in_blob` points at `input`, which lives across the call; `out_blob` is a live out parameter. The OS
    // allocates the output, which is copied and freed below.
    let ok = unsafe {
        match direction {
            Direction::Protect => CryptProtectData(
                &in_blob,
                PCWSTR::null(),
                entropy_pointer,
                None,
                None,
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut out_blob,
            ),
            Direction::Unprotect => CryptUnprotectData(
                &in_blob,
                None,
                entropy_pointer,
                None,
                None,
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut out_blob,
            ),
        }
    };
    if ok.is_err() {
        return None;
    }
    let bytes = copy_and_free(out_blob);
    Some(bytes)
}

/// Copies an OS-allocated blob into a Vec and frees the original.
fn copy_and_free(blob: CRYPT_INTEGER_BLOB) -> Vec<u8> {
    if blob.pbData.is_null() {
        return Vec::new();
    }
    // SAFETY: on success the OS set pbData to cbData readable bytes, which stay valid until LocalFree below.
    let bytes = unsafe { std::slice::from_raw_parts(blob.pbData, blob.cbData as usize) }.to_vec();
    // SAFETY: the same bytes, still owned by the OS allocation. After an unprotect they are the plain secret.
    unsafe { std::slice::from_raw_parts_mut(blob.pbData, blob.cbData as usize) }.zeroize();
    // SAFETY: pbData came from LocalAlloc inside CryptProtectData or CryptUnprotectData, so LocalFree owns it.
    unsafe { LocalFree(HLOCAL(blob.pbData as *mut c_void)) };
    bytes
}
