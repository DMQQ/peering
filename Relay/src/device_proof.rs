//! Proving that a connection is the device whose ID it is claiming.
//!
//! **The problem this closes.** A device ID is a name. `DeviceIdentity` in the app says so in as
//! many words — "deliberately *not* a secret" — and it is broadcast in the Mac's Bonjour TXT record
//! to everyone on the network and printed into the pairing QR code. That is fine for what it was
//! for, which is letting two devices find each other, and it stopped being fine when
//! `RegisterHost` started writing that name into a table. `HostRegistry::put` inserted without
//! checking, so anyone who had learned a Mac's ID could register it and take the entry away from
//! the Mac that owns it: that Mac becomes unreachable through the relay until it reconnects, and
//! the attacker can be scripted to do it again.
//!
//! **A signature rather than a shared secret**, and the reason is that every device already holds
//! the key. Each side has a long-term P-256 key in the keychain, and the pairing handshake already
//! pins its public bytes on the other side. So there is nothing to mint, nothing to store
//! separately, and no new way to lose access: a device that has lost this key cannot pair either.
//!
//! **What it does not do.** It does not authenticate the *session*, and it is not meant to. A Mac
//! that proves its ID is still a Mac that has to pass the pairing handshake before anyone sees its
//! screen, and the relay has never been able to read what it carries. What this buys is narrow and
//! worth stating exactly: a connection can no longer claim an ID it cannot sign for. That is one
//! denial-of-service closed, and no privacy property changed either way.

use ring::signature::{ECDSA_P256_SHA256_ASN1, UnparsedPublicKey};

use crate::protocol::hex_bytes;

/// The largest public key that will be looked at: an uncompressed P-256 point is 65 bytes, and
/// nothing longer than that can be one.
const MAX_PUBLIC_KEY_BYTES: usize = 65;
/// The largest signature that will be looked at. A DER ECDSA signature over P-256 is at most 72
/// bytes, and a longer one is not a signature whatever it is.
const MAX_SIGNATURE_BYTES: usize = 72;

/// How stale a signed registration may be.
///
/// Five minutes either way, which is generous for a clock that is set by the system and corrected
/// on its own, and short enough that a message captured off the wire is worthless by the time
/// anyone could replay it. The asymmetry is deliberate: a device whose clock is behind must not be
/// refused, and a device whose clock is ahead must not be either.
pub const PROOF_WINDOW_SECS: u64 = 300;

/// The bytes a device signs to register.
///
/// **Canonical and versioned**, because both ends build this string independently and a signature
/// over two different spellings of the same fact is a signature that fails for reasons nobody can
/// see. The version tag is first so that a later scheme is a different string rather than a
/// silently incompatible one, and the fields are newline-separated in a fixed order.
///
/// A device ID is a UUID and a time is a decimal integer, so neither can contain a newline and no
/// pair of distinct inputs can produce the same string. That is the whole reason for choosing a
/// delimiter that cannot appear in the data rather than escaping one that can.
pub fn payload(device_id: &str, proof_time: u64) -> String {
    format!("peeringd-host-registration-v1\n{device_id}\n{proof_time}")
}

/// Whether a signature is genuinely this device's.
///
/// The public key is checked to be a point on P-256 as part of verifying, so a garbage key is a
/// failed proof rather than a panic, and a key that is not on the curve cannot be used to stand in
/// for one that is.
pub fn verifies(public_key_hex: &str, signature_hex: &str, payload: &[u8]) -> bool {
    // Both bounded before either is parsed, so a message cannot make this allocate by the megabyte
    // on the way to being refused. The caps are the largest a real value can be, not a guess.
    let Some(key) = hex_bytes(public_key_hex, MAX_PUBLIC_KEY_BYTES) else { return false };
    let Some(signature) = hex_bytes(signature_hex, MAX_SIGNATURE_BYTES) else { return false };
    UnparsedPublicKey::new(&ECDSA_P256_SHA256_ASN1, key)
        .verify(payload, &signature)
        .is_ok()
}

/// Whether a claimed time is close enough to now to be the one that was signed.
pub fn time_is_current(proof_time: u64, now: u64) -> bool {
    proof_time.abs_diff(now) <= PROOF_WINDOW_SECS
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::bytes_hex;
    use p256::ecdsa::{Signature, SigningKey, signature::Signer};

    /// Keys of this module's own, derived from a seed rather than taken from anywhere.
    fn key(seed: u8) -> SigningKey {
        SigningKey::from_bytes(&[seed; 32].into()).expect("a valid scalar")
    }

    /// The 65-byte uncompressed point, which is the encoding the app pins and signs with.
    fn uncompressed(signing: &SigningKey) -> String {
        bytes_hex(&signing.verifying_key().to_sec1_bytes())
    }

    /// DER, because that is what `SecKeyCreateSignature` with the X9.62 message algorithm emits,
    /// and a signature in the other encoding would verify here against a wire format the app does
    /// not send.
    fn sign(signing: &SigningKey, payload: &str) -> String {
        let signature: Signature = signing.sign(payload.as_bytes());
        bytes_hex(signature.to_der().as_bytes())
    }

    #[test]
    fn a_signature_over_the_payload_verifies() {
        let signing = key(7);
        let body = payload("A1B2", 1_760_000_000);
        assert!(verifies(&uncompressed(&signing), &sign(&signing, &body), body.as_bytes()));
    }

    #[test]
    fn another_device_key_does_not_verify() {
        let mine = key(7);
        let theirs = key(9);
        let body = payload("A1B2", 1_760_000_000);
        assert!(!verifies(&uncompressed(&theirs), &sign(&mine, &body), body.as_bytes()));
    }

    /// The property that makes the payload worth versioning: signing one device's registration
    /// must not authorise another device's.
    #[test]
    fn a_signature_for_one_device_does_not_cover_another() {
        let signing = key(7);
        let signed = payload("A1B2", 1_760_000_000);
        let attempted = payload("C3D4", 1_760_000_000);
        assert!(!verifies(
            &uncompressed(&signing),
            &sign(&signing, &signed),
            attempted.as_bytes()
        ));
    }

    #[test]
    fn a_signature_for_one_time_does_not_cover_another() {
        let signing = key(7);
        let signed = payload("A1B2", 1_760_000_000);
        let attempted = payload("A1B2", 1_760_000_600);
        assert!(!verifies(
            &uncompressed(&signing),
            &sign(&signing, &signed),
            attempted.as_bytes()
        ));
    }

    #[test]
    fn rubbish_is_a_failed_proof_and_not_a_panic() {
        let body = payload("A1B2", 1_760_000_000);
        assert!(!verifies("not hex", "also not hex", body.as_bytes()));
        assert!(!verifies("00", "00", body.as_bytes()));
        // A point that is not on the curve, which is the case a naive parser gets wrong.
        let off_curve = format!("04{}", "00".repeat(64));
        assert!(!verifies(&off_curve, &"00".repeat(70), body.as_bytes()));
    }

    #[test]
    fn the_time_window_is_symmetric_and_bounded() {
        let now = 1_760_000_000;
        assert!(time_is_current(now, now));
        assert!(time_is_current(now - PROOF_WINDOW_SECS, now), "a slow clock is not an attacker");
        assert!(time_is_current(now + PROOF_WINDOW_SECS, now), "nor a fast one");
        assert!(!time_is_current(now - PROOF_WINDOW_SECS - 1, now));
        assert!(!time_is_current(now + PROOF_WINDOW_SECS + 1, now));
    }

    /// The point of the whole module: a payload a device signed is not a payload that names it.
    #[test]
    fn the_payload_is_exactly_what_both_ends_build() {
        assert_eq!(
            payload("8B88D893-55BD-4F68-AF3F-E81D885A50A7", 1_760_000_000),
            "peeringd-host-registration-v1\n8B88D893-55BD-4F68-AF3F-E81D885A50A7\n1760000000"
        );
    }

    /// Documented so the Swift side can be read against it. See `RelayDeviceProof` in `RemoteCore`.
    #[test]
    fn the_key_is_the_uncompressed_point_the_app_already_pins() {
        let from_point = uncompressed(&key(7));
        assert_eq!(from_point.len(), 130, "65 bytes as hex");
        assert!(from_point.starts_with("04"), "uncompressed, not the compressed form");
    }

    #[test]
    fn an_oversized_key_or_signature_is_refused_rather_than_parsed() {
        let body = payload("A1B2", 1_760_000_000);
        let signing = key(7);
        let good_signature = sign(&signing, &body);

        // A key longer than any P-256 point, and a signature longer than any DER ECDSA one.
        let long_key = format!("04{}", "ab".repeat(200));
        assert!(!verifies(&long_key, &good_signature, body.as_bytes()));
        let long_signature = "ab".repeat(500);
        assert!(!verifies(&uncompressed(&signing), &long_signature, body.as_bytes()));
        // An odd number of hex digits is not hex.
        assert!(!verifies(&uncompressed(&signing), "abc", body.as_bytes()));
    }
}
