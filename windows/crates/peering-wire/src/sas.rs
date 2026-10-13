//! Short authentication string pairing maths. See docs/protocol.md section 6.

use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

pub const COMMITMENT_DOMAIN: &[u8] = b"MacCast-Pairing-commit-v1";
pub const SAS_DOMAIN: &[u8] = b"MacCast-Pairing-SAS-v1";
pub const PROOF_DOMAIN: &[u8] = b"MacCast-Pairing-proof-v1";
pub const DIGIT_COUNT: usize = 6;

pub fn commitment(ephemeral_public_key: &[u8], nonce: &[u8]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(COMMITMENT_DOMAIN);
    hasher.update(ephemeral_public_key);
    hasher.update(nonce);
    hasher.finalize().into()
}

pub fn verify_commitment(commitment_bytes: &[u8], ephemeral_public_key: &[u8], nonce: &[u8]) -> bool {
    commitment_bytes.ct_eq(&commitment(ephemeral_public_key, nonce)).into()
}

/// Every exchanged field, in the fixed order of `serialized`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingTranscript {
    pub protocol_version: u16,
    pub client_id: String,
    pub server_id: String,
    pub client_ephemeral_public_key: Vec<u8>,
    pub server_ephemeral_public_key: Vec<u8>,
    pub client_nonce: Vec<u8>,
    pub server_nonce: Vec<u8>,
    pub server_identity_public_key: Vec<u8>,
}

impl PairingTranscript {
    /// Length prefixes are load-bearing: without them bytes could shift across a field boundary and give the same digits.
    pub fn serialized(&self) -> Vec<u8> {
        let mut out = Vec::new();
        let mut put = |bytes: &[u8]| {
            out.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
            out.extend_from_slice(bytes);
        };
        put(SAS_DOMAIN);
        put(&self.protocol_version.to_be_bytes());
        put(self.client_id.as_bytes());
        put(self.server_id.as_bytes());
        put(&self.client_ephemeral_public_key);
        put(&self.server_ephemeral_public_key);
        put(&self.client_nonce);
        put(&self.server_nonce);
        put(&self.server_identity_public_key);
        out
    }

    pub fn code(&self) -> String {
        let digest = Sha256::digest(self.serialized());
        let value = u32::from_be_bytes([digest[0], digest[1], digest[2], digest[3]]);
        format!("{:06}", value % 1_000_000)
    }

    /// Shows that the confirming phone saw the host screen, where the QR carried the secret.
    pub fn proof(&self, secret: &[u8]) -> Vec<u8> {
        let mut mac = Hmac::<Sha256>::new_from_slice(secret).expect("HMAC accepts any key length");
        mac.update(PROOF_DOMAIN);
        mac.update(&self.serialized());
        mac.finalize().into_bytes().to_vec()
    }

    pub fn verify_proof(&self, proof: &[u8], secret: &[u8]) -> bool {
        proof.ct_eq(&self.proof(secret)).into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vectors_dir::load;

    fn from_vector() -> (PairingTranscript, serde_json::Value) {
        let v = load("crypto.json");
        let s = &v["sas"];
        let field = |name: &str| hex::decode(s[name].as_str().unwrap()).unwrap();
        let transcript = PairingTranscript {
            protocol_version: s["protocolVersion"].as_u64().unwrap() as u16,
            client_id: s["clientID"].as_str().unwrap().into(),
            server_id: s["serverID"].as_str().unwrap().into(),
            client_ephemeral_public_key: field("clientEphemeral"),
            server_ephemeral_public_key: field("serverEphemeral"),
            client_nonce: field("clientNonce"),
            server_nonce: field("serverNonce"),
            server_identity_public_key: field("serverIdentity"),
        };
        (transcript, v)
    }

    #[test]
    fn transcript_bytes_and_code_match_the_vector() {
        let (t, v) = from_vector();
        assert_eq!(hex::encode(t.serialized()), v["sas"]["transcript"].as_str().unwrap());
        assert_eq!(t.code(), "365357");
    }

    #[test]
    fn commitment_matches_the_vector_and_verifies() {
        let v = load("crypto.json");
        let c = &v["commitment"];
        let eph = hex::decode(c["ephemeral"].as_str().unwrap()).unwrap();
        let nonce = hex::decode(c["nonce"].as_str().unwrap()).unwrap();
        let expected = hex::decode(c["commitment"].as_str().unwrap()).unwrap();
        assert_eq!(commitment(&eph, &nonce).to_vec(), expected);
        assert!(verify_commitment(&expected, &eph, &nonce));
        assert!(!verify_commitment(&expected, &eph, b"other nonce"));
    }

    #[test]
    fn proof_matches_the_vector_and_rejects_a_wrong_secret() {
        let (t, v) = from_vector();
        let secret = hex::decode(v["proof"]["secret"].as_str().unwrap()).unwrap();
        let proof = hex::decode(v["proof"]["proof"].as_str().unwrap()).unwrap();
        assert_eq!(t.proof(&secret), proof);
        assert!(t.verify_proof(&proof, &secret));
        assert!(!t.verify_proof(&proof, b"another secret!!"));
    }

    #[test]
    fn changing_any_field_changes_the_transcript() {
        let (base, _) = from_vector();
        let mut other = base.clone();
        other.client_id.push('x');
        assert_ne!(other.serialized(), base.serialized());
        let mut shifted = base.clone();
        shifted.client_id = "iphone-15-pro-max".into();
        shifted.server_id = "mac-studio-01".into();
        assert_eq!(shifted.serialized(), base.serialized());
    }
}
