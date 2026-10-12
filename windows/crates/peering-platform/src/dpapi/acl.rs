//! Limits the secrets directory to its owner and SYSTEM, so a different account on the same PC cannot list or open it
//! even if the profile folder was loosened.

use std::ffi::c_void;
use std::io;
use std::iter::once;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;

use windows::core::PCWSTR;
use windows::Win32::Foundation::{LocalFree, HLOCAL};
use windows::Win32::Security::Authorization::{ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1};
use windows::Win32::Security::{
    SetFileSecurityW, DACL_SECURITY_INFORMATION, PROTECTED_DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR,
};

/// A protected DACL (nothing inherited) that gives full control to the owner and to SYSTEM, inherited by what is
/// created inside.
const OWNER_AND_SYSTEM_ONLY: &str = "D:P(A;OICI;FA;;;OW)(A;OICI;FA;;;SY)";

pub fn restrict_to_owner(directory: &Path) -> io::Result<()> {
    let descriptor_text: Vec<u16> = OWNER_AND_SYSTEM_ONLY.encode_utf16().chain(once(0)).collect();
    let path: Vec<u16> = directory.as_os_str().encode_wide().chain(once(0)).collect();
    let mut descriptor = PSECURITY_DESCRIPTOR::default();
    // SAFETY: `descriptor_text` is a NUL terminated UTF-16 string that outlives the call, and `descriptor` is a live out
    // parameter. On success the OS allocates the descriptor, which is freed below.
    unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            PCWSTR(descriptor_text.as_ptr()),
            SDDL_REVISION_1,
            &mut descriptor,
            None,
        )
        .map_err(|error| io::Error::other(error.to_string()))?;
    }
    // SAFETY: `path` is a NUL terminated UTF-16 string that outlives the call and `descriptor` was built above.
    let applied = unsafe {
        SetFileSecurityW(
            PCWSTR(path.as_ptr()),
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            descriptor,
        )
    };
    // SAFETY: the descriptor came from the OS allocator in the conversion call and is not used again.
    unsafe { LocalFree(HLOCAL(descriptor.0 as *mut c_void)) };
    applied.ok().map_err(|error| io::Error::other(error.to_string()))
}
