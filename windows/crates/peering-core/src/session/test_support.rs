//! Deterministic collaborators for the session tests. Nothing here is compiled into the library.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard, PoisonError};

use super::actions::SessionAction;
use super::deps::{PairedDevice, PinStore, Random};
use super::handshake::{HostConfig, HostSession};
use crate::fakes::clock::FakeClock;
use crate::ports::clock::Clock;
use peering_wire::framing::{Frame, MessageKind};
use std::sync::Arc;

pub const CLIENT_ID: &str = "11111111-2222-3333-4444-555555555555";
pub const CLIENT_NAME: &str = "Pixel 9";
pub const HOST_ID: &str = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE";
pub const CLIENT_KEY: [u8; 65] = [0xC7; 65];
pub const HOST_KEY: [u8; 65] = [0xE5; 65];
pub const CLIENT_EPHEMERAL: [u8; 65] = [0xA1; 65];
pub const HOST_EPHEMERAL: [u8; 65] = [0xB2; 65];
pub const CLIENT_NONCE: [u8; 32] = [0xC3; 32];
pub const HOST_NONCE: [u8; 32] = [0xD4; 32];
pub const SECRET: [u8; 16] = [0x5E; 16];
pub const UNIX_NOW: u64 = 1_800_000_000;

/// Returns the same values on every call, so a test knows what the host committed to.
pub struct FixedRandom;

impl Random for FixedRandom {
    fn ephemeral_public_key(&mut self) -> Vec<u8> {
        HOST_EPHEMERAL.to_vec()
    }

    fn nonce(&mut self) -> Vec<u8> {
        HOST_NONCE.to_vec()
    }

    fn secret(&mut self) -> Vec<u8> {
        SECRET.to_vec()
    }
}

/// A pin store in a map. `set_fail_writes(true)` makes `record` report failure and store nothing.
#[derive(Default)]
pub struct MemoryPins {
    devices: Mutex<HashMap<String, PairedDevice>>,
    fail_writes: AtomicBool,
}

impl MemoryPins {
    pub fn with_device(device: PairedDevice) -> Self {
        let pins = Self::default();
        lock(&pins.devices).insert(device.id.clone(), device);
        pins
    }

    pub fn set_fail_writes(&self, fail: bool) {
        self.fail_writes.store(fail, Ordering::SeqCst);
    }
}

impl PinStore for MemoryPins {
    fn pin_for(&self, client_id: &str) -> Option<Vec<u8>> {
        lock(&self.devices).get(client_id).map(|device| device.public_key.clone())
    }

    fn record(&self, device: &PairedDevice) -> bool {
        if self.fail_writes.load(Ordering::SeqCst) {
            return false;
        }
        lock(&self.devices).insert(device.id.clone(), device.clone());
        true
    }

    fn mark_seen(&self, client_id: &str, unix_seconds: u64) {
        if let Some(device) = lock(&self.devices).get_mut(client_id) {
            device.last_seen_unix = unix_seconds;
        }
    }

    fn devices(&self) -> Vec<PairedDevice> {
        let mut devices: Vec<PairedDevice> = lock(&self.devices).values().cloned().collect();
        devices.sort_by(|a, b| a.id.cmp(&b.id));
        devices
    }

    fn revoke(&self, client_id: &str) -> bool {
        lock(&self.devices).remove(client_id).is_some()
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

pub fn host_config(peer_public_key: Option<Vec<u8>>) -> HostConfig {
    HostConfig {
        host_id: HOST_ID.to_owned(),
        host_name: "Studio Mac".to_owned(),
        identity_public_key: HOST_KEY.to_vec(),
        mac_addresses: vec!["aa:bb:cc:dd:ee:ff".to_owned()],
        peer_public_key,
        arrived_through_relay: false,
    }
}

pub fn fake_clock() -> Arc<FakeClock> {
    Arc::new(FakeClock::new(0.0, UNIX_NOW))
}

pub fn session_with(pins: Arc<MemoryPins>, peer_public_key: Option<Vec<u8>>) -> HostSession {
    let clock: Arc<dyn Clock> = fake_clock();
    HostSession::new(
        host_config(peer_public_key),
        super::deps::HostDeps { random: Box::new(FixedRandom), pins, clock },
    )
}

pub fn role_frame(role: u8) -> Frame {
    Frame::new(MessageKind::ConnectionRole, vec![role])
}

pub fn client_hello_json(version: u16, client_id: &str, extra: &str) -> Frame {
    let json = format!(
        r#"{{"clientID":"{client_id}","clientName":"{CLIENT_NAME}","protocolVersion":{version},"wantsPairing":true{extra}}}"#
    );
    Frame::new(MessageKind::ClientHello, json.into_bytes())
}

pub fn sent_frames(actions: &[SessionAction]) -> Vec<&Frame> {
    actions
        .iter()
        .filter_map(|action| match action {
            SessionAction::Send(frame) => Some(frame),
            _ => None,
        })
        .collect()
}

pub fn find_close(actions: &[SessionAction]) -> Option<&super::actions::CloseReason> {
    actions.iter().find_map(|action| match action {
        SessionAction::Close(reason) => Some(reason),
        _ => None,
    })
}
