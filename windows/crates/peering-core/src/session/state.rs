//! Where a host control connection is in its handshake, and the liveness phase that follows from it.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HandshakeState {
    AwaitingRole,
    AwaitingHello,
    AwaitingClientCommit,
    AwaitingClientReveal,
    AwaitingConfirmation,
    AwaitingApproval,
    Ready,
    Failed,
}

/// How long a silent client may stay, which depends on what it has proven.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostPhase {
    Authorized,
    Unauthenticated,
    AwaitingApproval,
}

impl HandshakeState {
    pub fn phase(self) -> HostPhase {
        match self {
            Self::Ready => HostPhase::Authorized,
            Self::AwaitingApproval => HostPhase::AwaitingApproval,
            _ => HostPhase::Unauthenticated,
        }
    }
}
