//! Reads the two OS signals behind `SessionState`: whether the input desktop is the default one, and the WTS lock flag.

use std::ffi::c_void;

use windows::core::PWSTR;
use windows::Win32::Foundation::HANDLE;
use windows::Win32::System::RemoteDesktop::{
    WTSFreeMemory, WTSQuerySessionInformationW, WTSINFOEXW, WTSSessionInfoEx, WTS_CURRENT_SERVER_HANDLE,
    WTS_CURRENT_SESSION,
};
use windows::Win32::System::StationsAndDesktops::{
    CloseDesktop, GetUserObjectInformationW, OpenInputDesktop, DESKTOP_CONTROL_FLAGS, DESKTOP_READOBJECTS, HDESK,
    UOI_NAME,
};

use crate::session_state::session_flags_say_locked;

const DEFAULT_DESKTOP_NAME: &str = "Default";
const NAME_BUFFER_UNITS: usize = 64;
const WTS_INFO_LEVEL_1: u32 = 1;

/// The secure desktop refuses this open to an ordinary process, so a failed open means the desktop is not the default.
pub fn input_desktop_is_default() -> bool {
    // SAFETY: OpenInputDesktop takes no pointers; the handle it returns is closed below.
    let Ok(desktop) = (unsafe { OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_READOBJECTS) }) else {
        return false;
    };
    let name = desktop_name(desktop);
    // SAFETY: the handle came from OpenInputDesktop and is closed exactly once.
    let _ = unsafe { CloseDesktop(desktop) };
    name.as_deref() == Some(DEFAULT_DESKTOP_NAME)
}

fn desktop_name(desktop: HDESK) -> Option<String> {
    let mut buffer = [0u16; NAME_BUFFER_UNITS];
    let mut needed = 0u32;
    let byte_length = (NAME_BUFFER_UNITS * 2) as u32;
    // SAFETY: the buffer and length describe the same writable memory, and `needed` is a live out parameter.
    unsafe {
        GetUserObjectInformationW(
            HANDLE(desktop.0),
            UOI_NAME,
            Some(buffer.as_mut_ptr() as *mut c_void),
            byte_length,
            Some(&mut needed),
        )
        .ok()?;
    }
    let end = buffer.iter().position(|&unit| unit == 0).unwrap_or(buffer.len());
    Some(String::from_utf16_lossy(&buffer[..end]))
}

/// False when the session cannot be queried, so an unreadable lock state is never reported as locked.
pub fn session_locked() -> bool {
    let mut buffer = PWSTR::null();
    let mut bytes = 0u32;
    // SAFETY: on success the OS allocates `buffer`, which is freed with WTSFreeMemory below; both out pointers are live.
    let queried = unsafe {
        WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, WTS_CURRENT_SESSION, WTSSessionInfoEx, &mut buffer, &mut bytes)
    };
    if queried.is_err() || buffer.is_null() {
        return false;
    }
    // SAFETY: the buffer holds a WTSINFOEXW until it is freed below, and the level is checked before the union is read.
    let locked = unsafe {
        let info = &*(buffer.0 as *const WTSINFOEXW);
        info.Level == WTS_INFO_LEVEL_1 && session_flags_say_locked(info.Data.WTSInfoExLevel1.SessionFlags)
    };
    // SAFETY: `buffer` was allocated by WTSQuerySessionInformationW and is freed exactly once.
    unsafe { WTSFreeMemory(buffer.0 as *mut c_void) };
    locked
}
