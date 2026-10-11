//! Short authentication string pairing: commitment, reveal, code, then confirmation by proof or approval.

use peering_wire::framing::{Frame, MessageKind};
use peering_wire::handshake::{PairConfirm, PairResult, PairingCommit, PairingReveal};
use peering_wire::sas::{self, PairingTranscript};

use super::{decode_control, send_json, Exchange, HostSession, Verification, PROTOCOL_VERSION};
use crate::session::actions::{CloseReason, HostEvent, SessionAction};
use crate::session::deps::PairedDevice;
use crate::session::state::HandshakeState;

impl HostSession {
    /// The host commits before it sees the client's reveal, so the client cannot choose its digits after the fact.
    pub(super) fn begin_pairing(&mut self, out: &mut Vec<SessionAction>) -> Result<(), CloseReason> {
        let ephemeral_public_key = self.deps.random.ephemeral_public_key();
        let nonce = self.deps.random.nonce();
        let commitment = sas::commitment(&ephemeral_public_key, &nonce);
        send_json(out, MessageKind::PairCommit, &PairingCommit { commitment: commitment.to_vec() });
        self.exchange = Some(Exchange { ephemeral_public_key, nonce, remote_commitment: None });
        self.state = HandshakeState::AwaitingClientCommit;
        Ok(())
    }

    pub(super) fn handle_client_commit(&mut self, frame: &Frame, out: &mut Vec<SessionAction>) -> Result<(), CloseReason> {
        let commit: PairingCommit = decode_control(frame, MessageKind::PairCommit)?;
        let exchange = self.exchange.as_mut().ok_or(CloseReason::UnexpectedFrame(frame.kind))?;
        exchange.remote_commitment = Some(commit.commitment);
        send_json(
            out,
            MessageKind::PairReveal,
            &PairingReveal {
                ephemeral_public_key: exchange.ephemeral_public_key.clone(),
                nonce: exchange.nonce.clone(),
            },
        );
        self.state = HandshakeState::AwaitingClientReveal;
        Ok(())
    }

    pub(super) fn handle_client_reveal(&mut self, frame: &Frame, out: &mut Vec<SessionAction>) -> Result<(), CloseReason> {
        let reveal: PairingReveal = decode_control(frame, MessageKind::PairReveal)?;
        let exchange = self.exchange.as_ref().ok_or(CloseReason::UnexpectedFrame(frame.kind))?;
        let commitment = exchange.remote_commitment.as_deref().ok_or(CloseReason::UnexpectedFrame(frame.kind))?;
        if !sas::verify_commitment(commitment, &reveal.ephemeral_public_key, &reveal.nonce) {
            return Err(CloseReason::CommitmentMismatch);
        }
        let transcript = PairingTranscript {
            protocol_version: PROTOCOL_VERSION,
            client_id: self.client_id.clone(),
            server_id: self.config.host_id.clone(),
            client_ephemeral_public_key: reveal.ephemeral_public_key,
            server_ephemeral_public_key: exchange.ephemeral_public_key.clone(),
            client_nonce: reveal.nonce,
            server_nonce: exchange.nonce.clone(),
            server_identity_public_key: self.config.identity_public_key.clone(),
        };
        let secret = self.deps.random.secret();
        out.push(SessionAction::Emit(HostEvent::PairingCode {
            code: transcript.code(),
            secret: secret.clone(),
            client_name: self.client_name.clone(),
            via_relay: self.config.arrived_through_relay,
        }));
        self.verification = Some(Verification { transcript, secret });
        self.state = HandshakeState::AwaitingConfirmation;
        Ok(())
    }

    pub(super) fn handle_pair_confirm(&mut self, frame: &Frame, out: &mut Vec<SessionAction>) -> Result<(), CloseReason> {
        let confirm: PairConfirm = decode_control(frame, MessageKind::PairConfirm)?;
        if !confirm.accepted {
            self.send_refusal("The codes did not match.", out);
            return Err(CloseReason::PairingRejected);
        }
        let verification = self.verification.as_ref().ok_or(CloseReason::UnexpectedFrame(frame.kind))?;
        let Some(proof) = confirm.proof else {
            // Typed digits prove nothing, since anyone can compute them from the handshake: the Mac's user decides.
            self.state = HandshakeState::AwaitingApproval;
            out.push(SessionAction::RequestApproval { client_name: self.client_name.clone() });
            return Ok(());
        };
        let proof_valid = verification.transcript.verify_proof(&proof, &verification.secret);
        if proof_valid {
            self.finish_pairing(out)
        } else {
            self.send_refusal("The pairing code was not accepted.", out);
            Err(CloseReason::PairingRejected)
        }
    }

    /// The Mac user's answer for a pairing that arrived without the QR secret. Ignored in any other state.
    pub fn resolve_approval(&mut self, approved: bool) -> Vec<SessionAction> {
        let mut out = Vec::new();
        if self.state != HandshakeState::AwaitingApproval {
            return out;
        }
        let result = if approved {
            self.finish_pairing(&mut out)
        } else {
            self.send_refusal("The pairing was declined on the Mac.", &mut out);
            Err(CloseReason::PairingRejected)
        };
        self.settle(result, &mut out);
        out
    }

    fn send_refusal(&self, reason: &str, out: &mut Vec<SessionAction>) {
        send_json(out, MessageKind::PairResult, &PairResult { accepted: false, reason: Some(reason.to_owned()) });
        out.push(SessionAction::Emit(HostEvent::PairingCompleted {
            client_name: self.client_name.clone(),
            accepted: false,
        }));
    }

    /// The client is told it is paired only after the pin is stored, because a write that failed would
    /// otherwise look like success until the next connection failed.
    fn finish_pairing(&mut self, out: &mut Vec<SessionAction>) -> Result<(), CloseReason> {
        let device = PairedDevice {
            id: self.client_id.clone(),
            name: self.client_name.clone(),
            public_key: self.peer_key.clone(),
            last_seen_unix: self.deps.clock.unix_seconds(),
        };
        if !self.deps.pins.record(&device) {
            self.send_refusal("Could not save the pairing.", out);
            return Err(CloseReason::PairingNotSaved);
        }
        send_json(out, MessageKind::PairResult, &PairResult { accepted: true, reason: None });
        out.push(SessionAction::Emit(HostEvent::PairingCompleted {
            client_name: self.client_name.clone(),
            accepted: true,
        }));
        self.state = HandshakeState::Ready;
        out.push(SessionAction::Authorized);
        Ok(())
    }
}
