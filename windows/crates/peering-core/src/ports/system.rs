//! Workstation actions the host carries out for a client. The Windows adapter locks the session; tests use the recording fake.

use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum SystemError {
    #[error("the workstation could not be locked: {0}")]
    LockFailed(String),
}

pub trait SystemActions {
    /// Whether this host can lock the workstation. The hello advertises the lock only when this is true.
    fn can_lock_workstation(&self) -> bool;
    fn lock_workstation(&mut self) -> Result<(), SystemError>;
}
