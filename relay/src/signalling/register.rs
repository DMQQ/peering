//! A Mac registering itself under a device id.

use tokio::sync::mpsc;
use tracing::{info, warn};

use super::proof::{ProofFields, ProofOutcome};
use super::{field_too_long, refuse, ConnectionState, HostRegistry, Settings, MAX_FIELD};
use crate::device_proof;
use crate::protocol::ServerMessage;
use crate::redact::tag;
use crate::stats::Refusal;

pub(super) struct Registration {
    pub device_id: String,
    pub name: String,
    pub protocol_version: u16,
    pub proof: ProofFields,
}

pub(super) async fn register_host(
    registration: Registration,
    self_tx: &mpsc::Sender<ServerMessage>,
    hosts: &HostRegistry,
    settings: &Settings,
    state: &mut ConnectionState,
) -> ServerMessage {
    match try_register(registration, self_tx, hosts, settings, state).await {
        Ok(reply) | Err(reply) => reply,
    }
}

/// The key the registration proved, `None` when it offered no complete proof. A partial proof is
/// not salvaged: guessing at a message this relay does not understand is how a check becomes a hole.
fn verified_key(proof: &ProofFields, device_id: &str) -> Result<Option<String>, ServerMessage> {
    match proof.check(|stamp| device_proof::payload(device_id, stamp)) {
        ProofOutcome::Verified(key) => Ok(Some(key)),
        ProofOutcome::Stale => {
            warn!(device_id = %tag(device_id), "a device registration was signed for a different time");
            Err(refuse(
                Some(Refusal::BadProof),
                "proofStale",
                "that registration was signed for a time this relay will not accept",
            ))
        }
        ProofOutcome::Invalid => {
            warn!(device_id = %tag(device_id), "a device registration did not prove the key it claimed");
            Err(refuse(
                Some(Refusal::BadProof),
                "proofInvalid",
                "that registration does not prove it comes from the device it names",
            ))
        }
        ProofOutcome::Absent | ProofOutcome::Incomplete => Ok(None),
    }
}

async fn try_register(
    registration: Registration,
    self_tx: &mpsc::Sender<ServerMessage>,
    hosts: &HostRegistry,
    settings: &Settings,
    state: &mut ConnectionState,
) -> Result<ServerMessage, ServerMessage> {
    let Registration { device_id, name, protocol_version, proof } = registration;
    if device_id.len() > MAX_FIELD || name.len() > MAX_FIELD {
        return Err(field_too_long());
    }

    let proved = verified_key(&proof, &device_id)?;
    if let Err(reason) = hosts.put(&device_id, protocol_version, self_tx.clone(), proved.as_deref()).await {
        // At warn: a device that lost its key and someone claiming an id they do not own look alike.
        warn!(device_id = %tag(&device_id), reason, "refused a device registration");
        return Err(refuse(Some(Refusal::BadProof), "deviceRefused", reason));
    }

    // One live registration per connection: a second replaces the first.
    if let Some(previous) = state.registered_as.replace(device_id.clone())
        && previous != device_id
    {
        hosts.remove_if_ours(&previous, self_tx).await;
    }
    info!(device_id = %tag(&device_id), protocol_version, proved = proved.is_some(), "host registered");
    Ok(ServerMessage::Registered { session_ttl_seconds: settings.session_ttl.as_secs() })
}
