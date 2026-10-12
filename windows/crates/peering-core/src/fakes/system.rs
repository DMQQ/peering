//! Records the workstation actions instead of carrying them out.

use peering_wire::handshake::NoticePayload;

use crate::ports::system::{SystemActions, SystemError};

#[derive(Debug, Default)]
pub struct RecordingSystem {
    available: bool,
    lock_failure: Option<String>,
    lock_calls: u32,
    notice: Option<NoticePayload>,
}

impl RecordingSystem {
    /// A host that can lock, and whose lock succeeds unless `lock_failure` says otherwise.
    pub fn new(available: bool, lock_failure: Option<String>) -> Self {
        Self { available, lock_failure, lock_calls: 0, notice: None }
    }

    /// The condition `session_notice` reports from now on.
    pub fn set_notice(&mut self, notice: Option<NoticePayload>) {
        self.notice = notice;
    }

    pub fn lock_calls(&self) -> u32 {
        self.lock_calls
    }
}

impl SystemActions for RecordingSystem {
    fn can_lock_workstation(&self) -> bool {
        self.available
    }

    fn lock_workstation(&mut self) -> Result<(), SystemError> {
        self.lock_calls += 1;
        match &self.lock_failure {
            Some(reason) => Err(SystemError::LockFailed(reason.clone())),
            None => Ok(()),
        }
    }

    fn session_notice(&self) -> Option<NoticePayload> {
        self.notice.clone()
    }
}
