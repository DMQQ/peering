//! Workstation actions for the host, through the Windows calls. The signed-in user may lock their own session, so no
//! elevation is needed.

use peering_core::ports::system::{SystemActions, SystemError};
use peering_wire::handshake::NoticePayload;

use crate::addresses::{adapter_addresses, wake_addresses};
use crate::session_state::{current_state, notice_for};
use windows::Win32::System::Power::{SetThreadExecutionState, ES_CONTINUOUS, ES_DISPLAY_REQUIRED, ES_SYSTEM_REQUIRED};
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

    fn session_notice(&self) -> Option<NoticePayload> {
        // Lost frames are not counted here: that state has no notice, so the signals alone decide.
        notice_for(current_state(0))
    }

    fn set_keep_awake(&mut self, awake: bool) {
        // The request lasts as long as the calling thread does, which is the host's runtime thread for the whole run.
        let state = if awake { ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED } else { ES_CONTINUOUS };
        // SAFETY: SetThreadExecutionState takes flags only. A zero result means the request was refused, and the PC then
        // sleeps as it would have.
        let _previous = unsafe { SetThreadExecutionState(state) };
    }

    fn hardware_addresses(&self) -> Vec<String> {
        wake_addresses(&adapter_addresses())
    }
}
