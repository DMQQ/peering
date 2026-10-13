//! The collaborators a host session needs from its caller: randomness and the pin store.

use std::sync::Arc;

use crate::ports::clock::Clock;

/// Fresh values for one pairing. The ephemeral key is a P-256 point as 65 uncompressed bytes; the core
/// never performs key agreement, so the bytes only feed the transcript.
pub trait Random {
    fn ephemeral_public_key(&mut self) -> Vec<u8>;
    fn nonce(&mut self) -> Vec<u8>;
    fn secret(&mut self) -> Vec<u8>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairedDevice {
    pub id: String,
    pub name: String,
    pub public_key: Vec<u8>,
    pub last_seen_unix: u64,
}

/// The paired clients, keyed by device id. `record` and `revoke` report whether the change was stored.
pub trait PinStore: Send + Sync {
    fn pin_for(&self, client_id: &str) -> Option<Vec<u8>>;
    fn record(&self, device: &PairedDevice) -> bool;
    fn mark_seen(&self, client_id: &str, unix_seconds: u64);
    fn devices(&self) -> Vec<PairedDevice>;
    fn revoke(&self, client_id: &str) -> bool;
}

pub struct HostDeps {
    pub random: Box<dyn Random>,
    pub pins: Arc<dyn PinStore>,
    pub clock: Arc<dyn Clock>,
}
