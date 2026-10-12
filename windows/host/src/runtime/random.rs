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
impl peering_core::video::lane::Random for SystemRandomSource {
    fn fill(&mut self, buffer: &mut [u8]) -> bool {
        SystemRandom::new().fill(buffer).is_ok()
    }
}

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

/// A uniform value in `0.0..1.0` for jitter. A failed generator gives 1.0, which is the unjittered wait.
pub fn unit_fraction() -> f64 {
    let mut buffer = [0u8; 4];
    if SystemRandom::new().fill(&mut buffer).is_err() {
        return 1.0;
    }
    f64::from(u32::from_le_bytes(buffer)) / (f64::from(u32::MAX) + 1.0)
}
