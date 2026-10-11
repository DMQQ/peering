//! Pairing fakes and the phone that pairs with the host.

use super::*;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use peering_wire::framing::{Frame, MessageKind};
use peering_wire::handshake::{ClientHello, PairConfirm, PairingCommit, PairingReveal};
use peering_wire::sas::{self, PairingTranscript};
use peering_core::session::deps::PairedDevice;

/// A pin store kept in a map. `set_fail_writes(true)` makes `record` report failure and store nothing.
#[derive(Default)]
pub struct MemoryPins {
    devices: Mutex<HashMap<String, PairedDevice>>,
    fail_writes: AtomicBool,
}

impl MemoryPins {
    pub fn with_device(device: PairedDevice) -> Self {
        let pins = Self::default();
        locked(&pins.devices).insert(device.id.clone(), device);
        pins
    }

    pub fn set_fail_writes(&self, fail: bool) {
        self.fail_writes.store(fail, Ordering::SeqCst);
    }
}

impl PinStore for MemoryPins {
    fn pin_for(&self, client_id: &str) -> Option<Vec<u8>> {
        locked(&self.devices).get(client_id).map(|device| device.public_key.clone())
    }

    fn record(&self, device: &PairedDevice) -> bool {
        if self.fail_writes.load(Ordering::SeqCst) {
            return false;
        }
        locked(&self.devices).insert(device.id.clone(), device.clone());
        true
    }

    fn mark_seen(&self, client_id: &str, unix_seconds: u64) {
        if let Some(device) = locked(&self.devices).get_mut(client_id) {
            device.last_seen_unix = unix_seconds;
        }
    }

    fn devices(&self) -> Vec<PairedDevice> {
        let mut devices: Vec<PairedDevice> = locked(&self.devices).values().cloned().collect();
        devices.sort_by(|a, b| a.id.cmp(&b.id));
        devices
    }

    fn revoke(&self, client_id: &str) -> bool {
        locked(&self.devices).remove(client_id).is_some()
    }
}


/// A phone that pairs with the host, computing the code from the values it actually received.
pub struct PairingClient {
    pub id: String,
    pub name: String,
    pub public_key: Vec<u8>,
    ephemeral: Vec<u8>,
    nonce: Vec<u8>,
    host_commitment: Option<Vec<u8>>,
    host_ephemeral: Option<Vec<u8>>,
    host_nonce: Option<Vec<u8>>,
}

impl PairingClient {
    pub fn new() -> Self {
        Self {
            id: CLIENT_ID.to_owned(),
            name: CLIENT_NAME.to_owned(),
            public_key: CLIENT_KEY.to_vec(),
            ephemeral: CLIENT_EPHEMERAL.to_vec(),
            nonce: CLIENT_NONCE.to_vec(),
            host_commitment: None,
            host_ephemeral: None,
            host_nonce: None,
        }
    }

    pub fn hello(&self) -> Frame {
        self.hello_with(|hello| hello)
    }

    /// A hello built from the defaults, with one field changed by the closure.
    pub fn hello_with(&self, edit: impl FnOnce(ClientHello) -> ClientHello) -> Frame {
        let hello = ClientHello {
            client_id: self.id.clone(),
            client_name: self.name.clone(),
            protocol_version: peering_core::session::handshake::PROTOCOL_VERSION,
            wants_pairing: true,
            capabilities: Default::default(),
            resume_source: None,
            lost_pairing: None,
            client_platform: Some("android".to_owned()),
            video_codecs: None,
        };
        encode_json(MessageKind::ClientHello, &edit(hello))
    }

    pub fn commit(&self) -> Frame {
        let commitment = sas::commitment(&self.ephemeral, &self.nonce).to_vec();
        encode_json(MessageKind::PairCommit, &PairingCommit { commitment })
    }

    /// Records the host's commitment, so its reveal can be checked against it.
    pub fn take_host_commit(&mut self, frame: &Frame) {
        let commit: PairingCommit = decode_json(frame);
        self.host_commitment = Some(commit.commitment);
    }

    pub fn reveal(&self) -> Frame {
        encode_json(
            MessageKind::PairReveal,
            &PairingReveal { ephemeral_public_key: self.ephemeral.clone(), nonce: self.nonce.clone() },
        )
    }

    /// Checks the host's reveal against its commitment and keeps the host's values for the code.
    pub fn take_host_reveal(&mut self, frame: &Frame) -> bool {
        let reveal: PairingReveal = decode_json(frame);
        let Some(commitment) = self.host_commitment.as_deref() else {
            return false;
        };
        if !sas::verify_commitment(commitment, &reveal.ephemeral_public_key, &reveal.nonce) {
            return false;
        }
        self.host_ephemeral = Some(reveal.ephemeral_public_key);
        self.host_nonce = Some(reveal.nonce);
        true
    }

    /// The six digit code this phone computes. It must equal the one the Mac shows.
    pub fn code(&self) -> String {
        self.transcript().code()
    }

    pub fn proof(&self, secret: &[u8]) -> Vec<u8> {
        self.transcript().proof(secret)
    }

    pub fn confirm(&self, accepted: bool, proof: Option<Vec<u8>>) -> Frame {
        encode_json(MessageKind::PairConfirm, &PairConfirm { accepted, proof })
    }

    fn transcript(&self) -> PairingTranscript {
        PairingTranscript {
            protocol_version: peering_core::session::handshake::PROTOCOL_VERSION,
            client_id: self.id.clone(),
            server_id: HOST_ID.to_owned(),
            client_ephemeral_public_key: self.ephemeral.clone(),
            server_ephemeral_public_key: self.host_ephemeral.clone().expect("the host reveal was taken"),
            client_nonce: self.nonce.clone(),
            server_nonce: self.host_nonce.clone().expect("the host reveal was taken"),
            server_identity_public_key: HOST_KEY.to_vec(),
        }
    }
}

/// Runs the control role and hello, then the commit and reveal exchange, and returns the phone's view of the code.
/// `session` must be unpaired and the phone unknown to it.
pub fn pair_up_to_code(session: &mut HostSession, phone: &mut PairingClient) -> (String, Vec<u8>) {
    session.on_frame(role_frame(CONTROL_ROLE));
    let hello_actions = session.on_frame(phone.hello());
    phone.take_host_commit(&sent_of(&hello_actions, MessageKind::PairCommit).expect("host commits first"));
    let host_reveal = session.on_frame(phone.commit());
    let reveal = sent_of(&host_reveal, MessageKind::PairReveal).expect("host reveals after the client commits");
    assert!(phone.take_host_reveal(&reveal), "the host reveal matches its commitment");
    let code_actions = session.on_frame(phone.reveal());
    let (code, secret) = pairing_code_of(&code_actions).expect("the Mac shows a code");
    assert_eq!(phone.code(), code, "both ends compute the same six digits");
    (code, secret)
}

