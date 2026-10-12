//! What the pairing UI observes and answers: the current offer, paired devices and approvals waiting on the Mac user.

use std::sync::Arc;

use peering_wire::pairing_payload;

use crate::session::actions::HostEvent;
use crate::session::deps::PinStore;

/// The code and QR content a phone scans or compares while pairing is under way.
#[derive(Debug, Clone, PartialEq)]
pub struct PairingOffer {
    /// The session that opened the offer. Only that session may replace or close it.
    pub session: u64,
    pub code: String,
    pub secret_hex: String,
    pub client_name: String,
    pub via_relay: bool,
    pub host_link: String,
    pub code_link: String,
    /// When the offer opened, in the caller's seconds.
    pub opened_at: f64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingApproval {
    pub id: u64,
    /// The caller's handle for the session waiting on this answer.
    pub session: u64,
    pub client_name: String,
}

/// The answer to route back to the session that asked for it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ApprovalDecision {
    pub session: u64,
    pub approved: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairedDeviceEntry {
    pub id: String,
    pub name: String,
    pub last_seen_unix: u64,
}

/// An offer older than this may be replaced by another session's, so a peer that opened one and went quiet cannot keep the
/// pairing screen from everyone else.
pub const OFFER_LIFETIME_SECONDS: f64 = 120.0;

/// Waiting approvals past this are refused outright, so a peer cannot bury the real prompt under its own.
pub const MAXIMUM_PENDING_APPROVALS: usize = 4;

pub struct PairingService {
    host_id: String,
    pins: Arc<dyn PinStore>,
    offer: Option<PairingOffer>,
    approvals: Vec<PendingApproval>,
    next_approval_id: u64,
}

impl PairingService {
    pub fn new(host_id: &str, pins: Arc<dyn PinStore>) -> Self {
        Self {
            host_id: host_id.to_owned(),
            pins,
            offer: None,
            approvals: Vec::new(),
            next_approval_id: 1,
        }
    }

    /// Only the events that change what the user sees are read: a new code opens the offer, a finished
    /// pairing closes it. One pairing is active at a time: while `session` is not the one that opened the offer, its
    /// events change nothing, unless the offer has outlived `OFFER_LIFETIME_SECONDS`. A session that renews its own offer
    /// keeps the time it first opened it.
    pub fn apply_event(&mut self, session: u64, event: &HostEvent, now: f64) {
        match event {
            HostEvent::PairingCode { code, secret, client_name, via_relay } => {
                if self.offer.as_ref().is_some_and(|offer| offer.session != session && now - offer.opened_at <= OFFER_LIFETIME_SECONDS) {
                    return;
                }
                self.offer = Some(PairingOffer {
                    session,
                    code: code.clone(),
                    secret_hex: hex(secret),
                    client_name: client_name.clone(),
                    via_relay: *via_relay,
                    host_link: pairing_payload::host_link(&self.host_id),
                    code_link: pairing_payload::code_link(code, Some(secret.as_slice())),
                    opened_at: self.offer.as_ref().filter(|offer| offer.session == session).map_or(now, |offer| offer.opened_at),
                });
            }
            HostEvent::PairingCompleted { .. } => self.close_offer_of(session),
            HostEvent::ClientConnected { .. } => {}
        }
    }

    pub fn offer(&self) -> Option<&PairingOffer> {
        self.offer.as_ref()
    }

    /// Queues a prompt for the user. When too many are waiting the answer comes back as a refusal for the caller to deliver.
    pub fn request_approval(&mut self, session: u64, client_name: &str) -> Result<u64, ApprovalDecision> {
        if self.approvals.len() >= MAXIMUM_PENDING_APPROVALS {
            return Err(ApprovalDecision { session, approved: false });
        }
        let id = self.next_approval_id;
        self.next_approval_id += 1;
        self.approvals.push(PendingApproval { id, session, client_name: client_name.to_owned() });
        Ok(id)
    }

    pub fn pending_approvals(&self) -> &[PendingApproval] {
        &self.approvals
    }

    pub fn approve(&mut self, id: u64) -> Option<ApprovalDecision> {
        self.decide(id, true)
    }

    pub fn decline(&mut self, id: u64) -> Option<ApprovalDecision> {
        self.decide(id, false)
    }

    /// Drops the approvals and the offer of a session that ended before the Mac user answered.
    pub fn forget_session(&mut self, session: u64) {
        self.approvals.retain(|approval| approval.session != session);
        self.close_offer_of(session);
    }

    fn close_offer_of(&mut self, session: u64) {
        if self.offer.as_ref().is_some_and(|offer| offer.session == session) {
            self.offer = None;
        }
    }

    pub fn paired_devices(&self) -> Vec<PairedDeviceEntry> {
        self.pins
            .devices()
            .into_iter()
            .map(|device| PairedDeviceEntry { id: device.id, name: device.name, last_seen_unix: device.last_seen_unix })
            .collect()
    }

    /// Returns whether a paired device with this id existed.
    pub fn revoke(&self, client_id: &str) -> bool {
        self.pins.revoke(client_id)
    }

    fn decide(&mut self, id: u64, approved: bool) -> Option<ApprovalDecision> {
        let position = self.approvals.iter().position(|approval| approval.id == id)?;
        let approval = self.approvals.remove(position);
        Some(ApprovalDecision { session: approval.session, approved })
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
#[path = "pairing_tests.rs"]
mod tests;
