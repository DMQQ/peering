//! A cap on connections that have not yet proven who they are. A LAN peer that opens handshakes and stalls would
//! otherwise use up the process's descriptors before any pairing check runs. The cap is global, and each address also has
//! a small share of it, so one host cannot fill it for everyone else.

use std::net::IpAddr;
use std::sync::{Arc, Mutex};

use peering_core::admission::{AddressKey, PerKeyLimit, PER_ADDRESS_LIMIT};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use super::lock::lock_ignoring_poison;

pub const MAXIMUM_PRE_AUTH_CONNECTIONS: usize = 32;

type AddressShares = Arc<Mutex<PerKeyLimit<AddressKey>>>;

#[derive(Clone)]
pub struct PreAuthGate {
    slots: Arc<Semaphore>,
    addresses: AddressShares,
}

/// Held by a connection until it is authorised or ends; dropping it frees the slot and the address's share.
pub struct PreAuthPermit {
    _slot: OwnedSemaphorePermit,
    share: Option<(AddressShares, AddressKey)>,
}

impl Drop for PreAuthPermit {
    fn drop(&mut self) {
        if let Some((addresses, key)) = self.share.take() {
            lock_ignoring_poison(&addresses).leave(key);
        }
    }
}

impl PreAuthGate {
    pub fn new(capacity: usize) -> Self {
        Self { slots: Arc::new(Semaphore::new(capacity)), addresses: Arc::new(Mutex::new(PerKeyLimit::new(PER_ADDRESS_LIMIT))) }
    }

    /// A slot with no address, for connections the host makes itself. `None` when the cap is reached.
    pub fn enter(&self) -> Option<PreAuthPermit> {
        self.slots.clone().try_acquire_owned().ok().map(|slot| PreAuthPermit { _slot: slot, share: None })
    }

    /// A slot for a connection from `address`. `None` when the cap is reached or the address already holds its share,
    /// and the caller drops the new connection.
    pub fn enter_from(&self, address: IpAddr) -> Option<PreAuthPermit> {
        let key = AddressKey::of(address);
        if !lock_ignoring_poison(&self.addresses).enter(key) {
            return None;
        }
        let slot = self.slots.clone().try_acquire_owned().ok();
        let Some(slot) = slot else {
            lock_ignoring_poison(&self.addresses).leave(key);
            return None;
        };
        Some(PreAuthPermit { _slot: slot, share: Some((self.addresses.clone(), key)) })
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

    fn address(text: &str) -> IpAddr {
        text.parse().expect("an address")
    }

    #[test]
    fn one_address_cannot_take_more_than_its_share_of_the_global_cap() {
        let gate = PreAuthGate::new(32);
        let held: Vec<_> = (0..PER_ADDRESS_LIMIT).map(|_| gate.enter_from(address("192.168.1.9")).expect("within the share")).collect();
        assert!(gate.enter_from(address("192.168.1.9")).is_none());
        assert!(gate.enter_from(address("192.168.1.10")).is_some(), "another address still has room");
        drop(held);
    }

    #[test]
    fn dropping_a_permit_returns_the_address_share() {
        let gate = PreAuthGate::new(32);
        let held: Vec<_> = (0..PER_ADDRESS_LIMIT).map(|_| gate.enter_from(address("10.0.0.2")).expect("within the share")).collect();
        drop(held);
        assert!(gate.enter_from(address("10.0.0.2")).is_some());
    }

    #[test]
    fn a_connection_refused_by_the_global_cap_does_not_keep_an_address_share() {
        let gate = PreAuthGate::new(1);
        let _only = gate.enter_from(address("10.0.0.2")).expect("room");
        for _ in 0..10 {
            assert!(gate.enter_from(address("10.0.0.3")).is_none());
        }
        drop(_only);
        let held: Vec<_> = (0..1).map(|_| gate.enter_from(address("10.0.0.3")).expect("the refused tries left no share")).collect();
        drop(held);
    }

    #[test]
    fn clones_share_one_cap() {
        let gate = PreAuthGate::new(1);
        let other = gate.clone();
        let _held = gate.enter().expect("room");
        assert!(other.enter().is_none());
    }
}
