//! Records the workstation actions instead of carrying them out.

use peering_wire::handshake::NoticePayload;

use crate::ports::system::{SystemActions, SystemError};

#[derive(Debug, Default)]
pub struct RecordingSystem {
    available: bool,
    lock_failure: Option<String>,
    lock_calls: u32,
    notice: Option<NoticePayload>,
    keep_awake_calls: Vec<bool>,
    hardware_addresses: Vec<String>,
}

impl RecordingSystem {
    /// A host that can lock, and whose lock succeeds unless `lock_failure` says otherwise.
    pub fn new(available: bool, lock_failure: Option<String>) -> Self {
        Self { available, lock_failure, lock_calls: 0, notice: None, keep_awake_calls: Vec::new(), hardware_addresses: Vec::new() }
    }

    /// The addresses `hardware_addresses` reports.
    pub fn with_hardware_addresses(mut self, addresses: &[&str]) -> Self {
        self.hardware_addresses = addresses.iter().map(|address| (*address).to_owned()).collect();
        self
    }

    /// The condition `session_notice` reports from now on.
    pub fn set_notice(&mut self, notice: Option<NoticePayload>) {
        self.notice = notice;
    }

    pub fn lock_calls(&self) -> u32 {
        self.lock_calls
    }

    /// Every value `set_keep_awake` was called with, in order.
    pub fn keep_awake_calls(&self) -> &[bool] {
        &self.keep_awake_calls
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

    fn set_keep_awake(&mut self, awake: bool) {
        self.keep_awake_calls.push(awake);
    }

    fn hardware_addresses(&self) -> Vec<String> {
        self.hardware_addresses.clone()
    }
}
