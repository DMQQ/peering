//! What a connecting client is metered as: which identity its allowance hangs from, and which plan.

use tracing::info;

use super::proof::{ProofFields, ProofOutcome};
use super::{unix_now, ConnectionState, Settings};
use crate::device_proof;
use crate::playbilling::{self, PlayRejection};
use crate::quota::Plan;
use crate::redact::tag;
use crate::storekit::{Rejection, Trust};

/// The plan a connect is metered by, how it was arrived at, and why a purchase was refused.
pub(super) struct Metering {
    pub plan: Plan,
    pub trust: Trust,
    pub refused: Option<&'static str>,
}

/// The device key when the client proved it, which makes a reinstall cost the same as staying
/// installed, or `None` to meter by the stated id.
///
/// A proof that fails is not a refusal: refusing a clock skewed client over metering would be an
/// outage for someone who did nothing wrong. The log line says which happened.
pub(super) fn metered_key(proof: &ProofFields, client_id: &str) -> Option<String> {
    match proof.check(|stamp| device_proof::client_payload(client_id, stamp)) {
        ProofOutcome::Verified(key) => Some(key),
        ProofOutcome::Absent => None,
        ProofOutcome::Invalid => {
            info!(client_id = %tag(client_id), "a client proof did not verify; metered by id");
            None
        }
        ProofOutcome::Stale => {
            info!(client_id = %tag(client_id), "a client proof was signed for a different time; metered by id");
            None
        }
        ProofOutcome::Incomplete => {
            info!(client_id = %tag(client_id), "a client proof was incomplete; metered by id");
            None
        }
    }
}

/// A Play purchase decides the plan when Play is configured and the client presents one. Otherwise
/// the Apple receipt decides.
pub(super) async fn meter(
    settings: &Settings,
    state: &mut ConnectionState,
    claimed: Plan,
    jws: Option<&str>,
    play: Option<(&str, &str)>,
    client_key: Option<&str>,
) -> Metering {
    match (settings.play.as_deref(), play) {
        (Some(verifier), Some((token, product))) => {
            let verdict = verifier
                .verdict(&mut state.play_purchases, product, token, client_key, unix_now())
                .await;
            let resolved = playbilling::resolve(settings.receipts.trusts_claims(), claimed, Some(verdict));
            Metering {
                plan: resolved.plan,
                trust: resolved.trust,
                refused: resolved.rejected.map(PlayRejection::reason),
            }
        }
        _ => {
            let resolved = state.receipts.resolve(&settings.receipts, claimed, jws);
            Metering {
                plan: resolved.plan,
                trust: resolved.trust,
                refused: resolved.rejected.map(Rejection::reason),
            }
        }
    }
}
