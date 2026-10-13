//! The phone's side of the pairing exchange: it commits, reveals and computes the code from the values it received.

use peering_core::session::handshake::PROTOCOL_VERSION;
use peering_wire::framing::{Frame, MessageKind};
use peering_wire::handshake::{PairingCommit, PairingReveal};
use peering_wire::sas::{self, PairingTranscript};

use super::{decode_json, encode_json, CLIENT_ID, HOST_ID, HOST_KEY};

const CLIENT_EPHEMERAL: [u8; 65] = [0xA1; 65];
const CLIENT_NONCE: [u8; 32] = [0xC3; 32];

pub struct PairingClient {
    ephemeral: Vec<u8>,
    nonce: Vec<u8>,
    host_commitment: Option<Vec<u8>>,
    host_ephemeral: Option<Vec<u8>>,
    host_nonce: Option<Vec<u8>>,
}

impl PairingClient {
    pub fn new() -> Self {
        Self {
            ephemeral: CLIENT_EPHEMERAL.to_vec(),
            nonce: CLIENT_NONCE.to_vec(),
            host_commitment: None,
            host_ephemeral: None,
            host_nonce: None,
        }
    }

    pub fn commit(&self) -> Frame {
        let commitment = sas::commitment(&self.ephemeral, &self.nonce).to_vec();
        encode_json(MessageKind::PairCommit, &PairingCommit { commitment })
    }

    pub fn reveal(&self) -> Frame {
        let reveal = PairingReveal { ephemeral_public_key: self.ephemeral.clone(), nonce: self.nonce.clone() };
        encode_json(MessageKind::PairReveal, &reveal)
    }

    pub fn take_host_commit(&mut self, frame: &Frame) {
        self.host_commitment = Some(decode_json::<PairingCommit>(frame).commitment);
    }

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

    fn transcript(&self) -> PairingTranscript {
        PairingTranscript {
            protocol_version: PROTOCOL_VERSION,
            client_id: CLIENT_ID.to_owned(),
            server_id: HOST_ID.to_owned(),
            client_ephemeral_public_key: self.ephemeral.clone(),
            server_ephemeral_public_key: self.host_ephemeral.clone().expect("the host reveal was taken"),
            client_nonce: self.nonce.clone(),
            server_nonce: self.host_nonce.clone().expect("the host reveal was taken"),
            server_identity_public_key: HOST_KEY.to_vec(),
        }
    }

    pub fn code(&self) -> String {
        self.transcript().code()
    }

    pub fn proof(&self, secret: &[u8]) -> Vec<u8> {
        self.transcript().proof(secret)
    }
}
