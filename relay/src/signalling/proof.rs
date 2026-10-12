//! Checking the signed device proof a message may carry.

use super::unix_now;
use crate::device_proof;

/// The three proof fields a message may carry.
pub(super) struct ProofFields {
    pub public_key: Option<String>,
    pub proof: Option<String>,
    pub proof_time: Option<u64>,
}

pub(super) enum ProofOutcome {
    /// The signature holds; carries the proven public key.
    Verified(String),
    /// None of the three fields was sent.
    Absent,
    /// One or two of the three fields were sent.
    Incomplete,
    /// Signed for a time the relay will not accept.
    Stale,
    /// The signature does not verify against the key.
    Invalid,
}

impl ProofFields {
    /// Checks the proof against the bytes `payload` builds for the signed time.
    pub(super) fn check(&self, payload: impl FnOnce(u64) -> String) -> ProofOutcome {
        match (self.public_key.as_deref(), self.proof.as_deref(), self.proof_time) {
            (Some(key), Some(signature), Some(stamp)) => {
                if !device_proof::time_is_current(stamp, unix_now()) {
                    ProofOutcome::Stale
                } else if device_proof::verifies(key, signature, payload(stamp).as_bytes()) {
                    ProofOutcome::Verified(key.to_string())
                } else {
                    ProofOutcome::Invalid
                }
            }
            (None, None, None) => ProofOutcome::Absent,
            _ => ProofOutcome::Incomplete,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fields(key: Option<&str>, proof: Option<&str>, time: Option<u64>) -> ProofFields {
        ProofFields { public_key: key.map(str::to_owned), proof: proof.map(str::to_owned), proof_time: time }
    }

    #[test]
    fn no_fields_is_absent_and_some_fields_are_incomplete() {
        assert!(matches!(fields(None, None, None).check(|_| String::new()), ProofOutcome::Absent));
        assert!(matches!(fields(Some("04"), None, None).check(|_| String::new()), ProofOutcome::Incomplete));
        assert!(matches!(fields(None, Some("30"), Some(1)).check(|_| String::new()), ProofOutcome::Incomplete));
    }

    #[test]
    fn a_time_far_from_now_is_stale_before_the_signature_is_looked_at() {
        assert!(matches!(fields(Some("04"), Some("30"), Some(1)).check(|_| String::new()), ProofOutcome::Stale));
    }

    #[test]
    fn a_current_time_with_a_bad_signature_is_invalid() {
        let now = unix_now();
        assert!(matches!(fields(Some("04"), Some("30"), Some(now)).check(|_| String::new()), ProofOutcome::Invalid));
    }
}
