//! Workstation actions for the host, through the Windows calls. The signed-in user may lock their own session, so no
//! elevation is needed.

use peering_core::ports::system::{SystemActions, SystemError};
use windows::Win32::System::Shutdown::LockWorkStation;

#[derive(Debug, Default)]
pub struct WindowsSystem;

impl SystemActions for WindowsSystem {
    fn can_lock_workstation(&self) -> bool {
        true
    }

    fn lock_workstation(&mut self) -> Result<(), SystemError> {
        // SAFETY: LockWorkStation takes no arguments and only asks the window station to lock.
        unsafe { LockWorkStation() }.map_err(|error| SystemError::LockFailed(error.to_string()))
    }
}
