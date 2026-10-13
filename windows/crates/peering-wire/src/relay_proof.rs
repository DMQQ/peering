//! Device proofs the relay checks before it trusts a registration or a referral. See docs/protocol/relay.md section 1.

pub const HOST_REGISTRATION_DOMAIN: &str = "peeringd-host-registration-v1";
pub const CLIENT_REGISTRATION_DOMAIN: &str = "peeringd-client-registration-v1";
pub const REFERRAL_DOMAIN: &str = "peeringd-referral-v1";

/// The signed string is UTF-8 with newline separators and no trailing newline.
pub fn host_payload(device_id: &str, proof_time: u64) -> Vec<u8> {
    join(&[HOST_REGISTRATION_DOMAIN, device_id, &proof_time.to_string()])
}

pub fn client_payload(client_id: &str, proof_time: u64) -> Vec<u8> {
    join(&[CLIENT_REGISTRATION_DOMAIN, client_id, &proof_time.to_string()])
}

pub fn referral_status_payload(client_id: &str, proof_time: u64) -> Vec<u8> {
    join(&[REFERRAL_DOMAIN, "status", client_id, &proof_time.to_string()])
}

pub fn redeem_referral_payload(client_id: &str, code: &str, proof_time: u64) -> Vec<u8> {
    let action = format!("redeem:{code}");
    join(&[REFERRAL_DOMAIN, &action, client_id, &proof_time.to_string()])
}

fn join(parts: &[&str]) -> Vec<u8> {
    parts.join("\n").into_bytes()
}

/// Hex strings as the relay reads them: `public_key` is the 65 byte point, `signature` is DER.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceProof {
    pub public_key: String,
    pub signature: String,
    pub proof_time: u64,
}

impl DeviceProof {
    pub fn new(public_key: &[u8], der_signature: &[u8], proof_time: u64) -> Self {
        Self {
            public_key: hex::encode(public_key),
            signature: hex::encode(der_signature),
            proof_time,
        }
    }
}

/// Implemented by the platform key store. `message` is the raw payload; the implementation hashes it with SHA-256 as
/// part of ECDSA, so the caller never pre-hashes.
pub trait ProofSigner {
    fn public_key(&self) -> Vec<u8>;
    fn sign(&self, message: &[u8]) -> Vec<u8>;
}

pub fn make_host_proof(signer: &dyn ProofSigner, device_id: &str, now_unix: u64) -> DeviceProof {
    sign_payload(signer, &host_payload(device_id, now_unix), now_unix)
}

pub fn make_client_proof(signer: &dyn ProofSigner, client_id: &str, now_unix: u64) -> DeviceProof {
    sign_payload(signer, &client_payload(client_id, now_unix), now_unix)
}

fn sign_payload(signer: &dyn ProofSigner, payload: &[u8], proof_time: u64) -> DeviceProof {
    DeviceProof::new(&signer.public_key(), &signer.sign(payload), proof_time)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vectors_dir::load;
    use std::cell::RefCell;

    struct FakeSigner {
        public_key: Vec<u8>,
        signature: Vec<u8>,
        signed: RefCell<Vec<Vec<u8>>>,
    }

    impl FakeSigner {
        fn new(public_key: Vec<u8>, signature: Vec<u8>) -> Self {
            Self { public_key, signature, signed: RefCell::new(Vec::new()) }
        }
    }

    impl ProofSigner for FakeSigner {
        fn public_key(&self) -> Vec<u8> {
            self.public_key.clone()
        }

        fn sign(&self, message: &[u8]) -> Vec<u8> {
            self.signed.borrow_mut().push(message.to_vec());
            self.signature.clone()
        }
    }

    fn vector(name: &str) -> String {
        load("crypto.json")["relayProofPayloads"][name]
            .as_str()
            .expect("payload vector is a string")
            .to_string()
    }

    #[test]
    fn host_payload_matches_the_vector() {
        assert_eq!(host_payload("DEV", 1760000000), vector("host").into_bytes());
    }

    #[test]
    fn client_payload_matches_the_vector() {
        assert_eq!(client_payload("CLI", 1760000000), vector("client").into_bytes());
    }

    #[test]
    fn referral_status_payload_matches_the_vector() {
        assert_eq!(
            referral_status_payload("CLI", 1760000000),
            vector("referralStatus").into_bytes()
        );
    }

    #[test]
    fn redeem_payload_matches_the_vector() {
        assert_eq!(
            redeem_referral_payload("CLI", "ABCD", 1760000000),
            vector("referralRedeem").into_bytes()
        );
    }

    #[test]
    fn hex_keeps_leading_zeros_and_is_lowercase() {
        let proof = DeviceProof::new(&[0x00, 0x0a, 0xff], &[0x01, 0xAB], 7);
        assert_eq!(proof.public_key, "000aff");
        assert_eq!(proof.signature, "01ab");
        assert_eq!(proof.proof_time, 7);
    }

    #[test]
    fn host_proof_signs_exactly_the_host_payload() {
        let signer = FakeSigner::new(vec![0x04, 0x01], vec![0x30, 0x06]);
        let proof = make_host_proof(&signer, "DEV", 1760000000);
        assert_eq!(signer.signed.borrow().as_slice(), [vector("host").into_bytes()]);
        assert_eq!(proof, DeviceProof::new(&[0x04, 0x01], &[0x30, 0x06], 1760000000));
    }

    #[test]
    fn client_proof_signs_exactly_the_client_payload() {
        let signer = FakeSigner::new(vec![0x04], vec![0x30]);
        let proof = make_client_proof(&signer, "CLI", 1760000000);
        assert_eq!(signer.signed.borrow().as_slice(), [vector("client").into_bytes()]);
        assert_eq!(proof.proof_time, 1760000000);
    }
}
