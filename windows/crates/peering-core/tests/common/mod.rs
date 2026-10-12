//! Helpers shared by the peering-core flow tests. Each test binary uses a different subset, hence the allows.
#![allow(dead_code, unused_imports)]

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use peering_core::fakes::clock::FakeClock;
use peering_core::ports::clock::Clock;
use peering_core::session::actions::{CloseReason, SessionAction};
use peering_core::session::deps::{HostDeps, PairedDevice, PinStore, Random};
use peering_core::session::handshake::{HostConfig, HostSession};
use peering_wire::framing::{Frame, MessageKind};
use peering_wire::handshake::PairResult;
use serde::de::DeserializeOwned;
use serde::Serialize;

pub mod dispatch;
pub mod pairing;
pub mod relay;
pub mod video;

pub use dispatch::*;
pub use pairing::*;
pub use relay::*;
pub use video::*;

pub const CLIENT_ID: &str = "11111111-2222-3333-4444-555555555555";
pub const CLIENT_NAME: &str = "Pixel 9";
pub const HOST_ID: &str = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE";
pub const HOST_NAME: &str = "Studio PC";
pub const CLIENT_KEY: [u8; 65] = [0xC7; 65];
pub const HOST_KEY: [u8; 65] = [0xE5; 65];
pub const CLIENT_EPHEMERAL: [u8; 65] = [0xA1; 65];
pub const HOST_EPHEMERAL: [u8; 65] = [0xB2; 65];
pub const CLIENT_NONCE: [u8; 32] = [0xC3; 32];
pub const HOST_NONCE: [u8; 32] = [0xD4; 32];
pub const SECRET: [u8; 16] = [0x5E; 16];
pub const UNIX_NOW: u64 = 1_800_000_000;
pub const MAC_ADDRESS: &str = "aa:bb:cc:dd:ee:ff";

pub use peering_core::session::test_support::FixedRandom;

pub fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

pub fn paired_device(public_key: &[u8]) -> PairedDevice {
    PairedDevice {
        id: CLIENT_ID.to_owned(),
        name: CLIENT_NAME.to_owned(),
        public_key: public_key.to_vec(),
        last_seen_unix: 1,
    }
}

pub fn host_config(peer_public_key: Option<Vec<u8>>) -> HostConfig {
    HostConfig {
        host_id: HOST_ID.to_owned(),
        host_name: HOST_NAME.to_owned(),
        identity_public_key: HOST_KEY.to_vec(),
        mac_addresses: vec![MAC_ADDRESS.to_owned()],
        peer_public_key,
        arrived_through_relay: false,
    }
}

pub fn clock_at(monotonic_seconds: f64) -> Arc<FakeClock> {
    Arc::new(FakeClock::new(monotonic_seconds, UNIX_NOW))
}

/// A host session whose clock is the one passed in, so a test can advance it.
pub fn host_session(pins: Arc<dyn PinStore>, peer_public_key: Option<Vec<u8>>, clock: Arc<dyn Clock>) -> HostSession {
    HostSession::new(
        host_config(peer_public_key),
        HostDeps { random: Box::new(FixedRandom), pins, clock },
    )
}

pub fn role_frame(role: u8) -> Frame {
    Frame::new(MessageKind::ConnectionRole, vec![role])
}

pub const CONTROL_ROLE: u8 = 1;
pub const VIDEO_ROLE: u8 = 2;

pub fn encode_json<T: Serialize>(kind: MessageKind, value: &T) -> Frame {
    Frame::new(kind, serde_json::to_vec(value).expect("test message serialises"))
}

pub fn decode_json<T: DeserializeOwned>(frame: &Frame) -> T {
    serde_json::from_slice(&frame.payload).expect("frame decodes")
}

pub fn sent_frames(actions: &[SessionAction]) -> Vec<Frame> {
    actions
        .iter()
        .filter_map(|action| match action {
            SessionAction::Send(frame) => Some(frame.clone()),
            _ => None,
        })
        .collect()
}

/// The first frame of `kind` the session sent in these actions.
pub fn sent_of(actions: &[SessionAction], kind: MessageKind) -> Option<Frame> {
    sent_frames(actions).into_iter().find(|frame| frame.kind == kind)
}

pub fn close_reason(actions: &[SessionAction]) -> Option<CloseReason> {
    actions.iter().find_map(|action| match action {
        SessionAction::Close(reason) => Some(reason.clone()),
        _ => None,
    })
}

pub fn has_authorised(actions: &[SessionAction]) -> bool {
    actions.contains(&SessionAction::Authorized)
}

pub fn pair_result_of(actions: &[SessionAction]) -> PairResult {
    let frame = sent_of(actions, MessageKind::PairResult).expect("a pairResult frame");
    decode_json(&frame)
}

/// The six digit code and the secret the Mac shows, from the event the session emits.
pub fn pairing_code_of(actions: &[SessionAction]) -> Option<(String, Vec<u8>)> {
    actions.iter().find_map(|action| match action {
        SessionAction::Emit(peering_core::session::actions::HostEvent::PairingCode { code, secret, .. }) => {
            Some((code.clone(), secret.clone()))
        }
        _ => None,
    })
}

