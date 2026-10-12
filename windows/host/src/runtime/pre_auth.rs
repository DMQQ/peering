//! A cap on connections that have not yet proven who they are. A LAN peer that opens handshakes and stalls would
//! otherwise use up the process's descriptors before any pairing check runs.

use std::sync::Arc;

use tokio::sync::{OwnedSemaphorePermit, Semaphore};

pub const MAXIMUM_PRE_AUTH_CONNECTIONS: usize = 32;

#[derive(Clone)]
pub struct PreAuthGate {
    slots: Arc<Semaphore>,
}

/// Held by a connection until it is authorised or ends; dropping it frees the slot.
pub struct PreAuthPermit {
    _slot: OwnedSemaphorePermit,
}

impl PreAuthGate {
    pub fn new(capacity: usize) -> Self {
        Self { slots: Arc::new(Semaphore::new(capacity)) }
    }

    /// `None` when the cap is reached, and the caller drops the new connection.
    pub fn enter(&self) -> Option<PreAuthPermit> {
        self.slots.clone().try_acquire_owned().ok().map(|slot| PreAuthPermit { _slot: slot })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_connection_past_the_cap_is_refused() {
        let gate = PreAuthGate::new(2);
        let _first = gate.enter().expect("room for the first");
        let _second = gate.enter().expect("room for the second");
        assert!(gate.enter().is_none());
    }

    #[test]
    fn dropping_a_permit_frees_its_slot() {
        let gate = PreAuthGate::new(1);
        let permit = gate.enter().expect("room");
        assert!(gate.enter().is_none());
        drop(permit);
        assert!(gate.enter().is_some());
    }

    #[test]
    fn clones_share_one_cap() {
        let gate = PreAuthGate::new(1);
        let other = gate.clone();
        let _held = gate.enter().expect("room");
        assert!(other.enter().is_none());
    }
}
