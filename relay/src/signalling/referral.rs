//! Invite codes: asking for one's own and redeeming a friend's.

use tracing::info;

use super::proof::{ProofFields, ProofOutcome};
use super::{field_too_long, unix_now, ConnectionState, Settings, MAX_FIELD};
use crate::device_proof;
use crate::protocol::ServerMessage;
use crate::redact::tag;
use crate::referrals::Standing;

/// Invite requests one socket may make before it is told to reconnect.
pub(super) const MAX_REFERRAL_REQUESTS_PER_CONNECTION: usize = 16;

/// The identity an invite request proves, which is the device key, or the reply to refuse with.
/// A missing or bad proof is a refusal here, unlike metering: an announced id would let one person
/// redeem once per install.
fn proven_identity(action: &str, client_id: &str, proof: &ProofFields) -> Result<String, ServerMessage> {
    match proof.check(|stamp| device_proof::referral_payload(action, client_id, stamp)) {
        ProofOutcome::Verified(key) => Ok(key),
        ProofOutcome::Absent | ProofOutcome::Incomplete => {
            Err(ServerMessage::error("proofRequired", "invites need a device key; update the app"))
        }
        ProofOutcome::Stale => Err(ServerMessage::error(
            "proofStale",
            "that request was signed for a time this relay will not accept",
        )),
        ProofOutcome::Invalid => Err(ServerMessage::error(
            "proofInvalid",
            "that request does not prove it comes from the device it names",
        )),
    }
}

fn reply(standing: Standing) -> ServerMessage {
    ServerMessage::Referral {
        code: standing.code,
        bonus_seconds: standing.bonus_seconds,
        bonus_ends_at: standing.bonus_ends_at,
        redeemed: standing.redeemed,
        invites_earned: standing.invites_earned,
        invites_max: standing.invites_max,
    }
}

/// The length limit and the per connection budget, in the order a request meets them.
fn admit(fields: &[&str], state: &mut ConnectionState) -> Result<(), ServerMessage> {
    if fields.iter().any(|field| field.len() > MAX_FIELD) {
        return Err(field_too_long());
    }
    if state.referral_requests >= MAX_REFERRAL_REQUESTS_PER_CONNECTION {
        return Err(ServerMessage::error(
            "tooManyRequests",
            "this connection has made too many invite requests; reconnect to try again",
        ));
    }
    state.referral_requests += 1;
    Ok(())
}

pub(super) fn status(
    client_id: String,
    proof: &ProofFields,
    settings: &Settings,
    state: &mut ConnectionState,
) -> ServerMessage {
    if let Err(refusal) = admit(&[&client_id], state) {
        return refusal;
    }
    let identity = match proven_identity("status", &client_id, proof) {
        Ok(identity) => identity,
        Err(refusal) => return refusal,
    };
    match settings.quota.referrals().standing(&identity, unix_now()) {
        Ok(standing) => reply(standing),
        Err(refusal) => ServerMessage::error(refusal.code(), refusal.message()),
    }
}

pub(super) fn redeem(
    client_id: String,
    code: String,
    proof: &ProofFields,
    settings: &Settings,
    state: &mut ConnectionState,
) -> ServerMessage {
    if let Err(refusal) = admit(&[&client_id, &code], state) {
        return refusal;
    }
    let identity = match proven_identity(&format!("redeem:{code}"), &client_id, proof) {
        Ok(identity) => identity,
        Err(refusal) => return refusal,
    };
    match settings.quota.referrals().redeem_from(&identity, &code, unix_now(), state.peer) {
        Ok(standing) => {
            info!(client_id = %tag(&client_id), "an invite code was redeemed");
            reply(standing)
        }
        Err(refusal) => {
            info!(client_id = %tag(&client_id), reason = refusal.code(), "an invite code was refused");
            ServerMessage::error(refusal.code(), refusal.message())
        }
    }
}
