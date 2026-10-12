//! Pairing and key material from the operating system's random source.

use peering_core::session::deps::Random;
use ring::agreement::{EphemeralPrivateKey, ECDH_P256};
use ring::rand::{SecureRandom, SystemRandom};

const NONCE_BYTES: usize = 32;
const SECRET_BYTES: usize = 16;

#[derive(Default)]
pub struct SystemRandomSource;

/// A failed generator returns an empty value. The pairing then fails on the client's length check instead of
/// proceeding with a value anyone could predict.
impl Random for SystemRandomSource {
    fn ephemeral_public_key(&mut self) -> Vec<u8> {
        EphemeralPrivateKey::generate(&ECDH_P256, &SystemRandom::new())
            .ok()
            .and_then(|key| key.compute_public_key().ok())
            .map(|public| public.as_ref().to_vec())
            .unwrap_or_default()
    }

    fn nonce(&mut self) -> Vec<u8> {
        self.bytes(NONCE_BYTES)
    }

    fn secret(&mut self) -> Vec<u8> {
        self.bytes(SECRET_BYTES)
    }
}

impl SystemRandomSource {
    fn bytes(&mut self, count: usize) -> Vec<u8> {
        let mut buffer = vec![0u8; count];
        if SystemRandom::new().fill(&mut buffer).is_err() {
            return Vec::new();
        }
        buffer
    }
}
