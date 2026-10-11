//! The host side of the control connection: role, hello and the decision between a paired resume and pairing.
//! Mirrors `apple/MacCastHost/Network/HostSession+Handshake.swift`; see docs/protocol.md sections 5 and 6.

mod pairing;

use peering_wire::command::RemoteCommand;
use peering_wire::framing::{ConnectionRole, Frame, MessageKind};
use peering_wire::handshake::{ClientHello, ServerCapabilities, ServerHello};
use peering_wire::source::CaptureSource;
use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::Value;

use super::actions::{CloseReason, HostEvent, SessionAction};
use super::deps::HostDeps;
use super::state::HandshakeState;

pub use super::deps::{PairedDevice, PinStore, Random};

pub const PROTOCOL_VERSION: u16 = 20;
pub const MAX_CONTROL_PAYLOAD: usize = 64 * 1024;
const MAX_IDENTIFIER_BYTES: usize = 256;

pub struct HostConfig {
    pub host_id: String,
    pub host_name: String,
    /// The 65 byte point of this Mac's identity key, as it appears in its certificate.
    pub identity_public_key: Vec<u8>,
    pub mac_addresses: Vec<String>,
    /// Taken from the transport's TLS certificate, never from a message. `None` closes the session.
    pub peer_public_key: Option<Vec<u8>>,
    pub arrived_through_relay: bool,
}

/// The pairing values one side has put on the wire, kept until the other side's reveal arrives.
pub(super) struct Exchange {
    pub(super) ephemeral_public_key: Vec<u8>,
    pub(super) nonce: Vec<u8>,
    pub(super) remote_commitment: Option<Vec<u8>>,
}

/// Everything the six digit code and the QR proof are computed from.
pub(super) struct Verification {
    pub(super) transcript: peering_wire::sas::PairingTranscript,
    pub(super) secret: Vec<u8>,
}

pub struct HostSession {
    config: HostConfig,
    deps: HostDeps,
    state: HandshakeState,
    client_id: String,
    client_name: String,
    peer_key: Vec<u8>,
    exchange: Option<Exchange>,
    verification: Option<Verification>,
}

impl HostSession {
    pub fn new(config: HostConfig, deps: HostDeps) -> Self {
        Self {
            config,
            deps,
            state: HandshakeState::AwaitingRole,
            client_id: String::new(),
            client_name: String::new(),
            peer_key: Vec::new(),
            exchange: None,
            verification: None,
        }
    }

    pub fn state(&self) -> HandshakeState {
        self.state
    }

    pub fn client_id(&self) -> &str {
        &self.client_id
    }

    pub fn client_name(&self) -> &str {
        &self.client_name
    }

    pub fn on_frame(&mut self, frame: Frame) -> Vec<SessionAction> {
        let mut out = Vec::new();
        let result = self.route(frame, &mut out);
        self.settle(result, &mut out);
        out
    }

    fn route(&mut self, frame: Frame, out: &mut Vec<SessionAction>) -> Result<(), CloseReason> {
        match self.state {
            HandshakeState::AwaitingRole => self.handle_role(&frame, out),
            HandshakeState::AwaitingHello => self.handle_client_hello(&frame, out),
            HandshakeState::AwaitingClientCommit => self.handle_client_commit(&frame, out),
            HandshakeState::AwaitingClientReveal => self.handle_client_reveal(&frame, out),
            HandshakeState::AwaitingConfirmation => self.handle_pair_confirm(&frame, out),
            HandshakeState::AwaitingApproval | HandshakeState::Failed => Ok(()),
            HandshakeState::Ready => {
                out.push(SessionAction::ForwardFrame(frame));
                Ok(())
            }
        }
    }

    /// Any refusal ends the session: the state parks at `Failed` and the caller is told to close.
    fn settle(&mut self, result: Result<(), CloseReason>, out: &mut Vec<SessionAction>) {
        if let Err(reason) = result {
            self.state = HandshakeState::Failed;
            out.push(SessionAction::Close(reason));
        }
    }

    fn handle_role(&mut self, frame: &Frame, out: &mut Vec<SessionAction>) -> Result<(), CloseReason> {
        if frame.kind != MessageKind::ConnectionRole {
            return Err(CloseReason::UnexpectedFrame(frame.kind));
        }
        let role = frame
            .payload
            .first()
            .and_then(|byte| ConnectionRole::from_byte(*byte))
            .ok_or(CloseReason::UnexpectedFrame(frame.kind))?;
        match role {
            ConnectionRole::Control => self.state = HandshakeState::AwaitingHello,
            ConnectionRole::Video => {
                // Parked, so the control state machine cannot read the next frame as a hello.
                self.state = HandshakeState::Failed;
                out.push(SessionAction::VideoConnection);
            }
        }
        Ok(())
    }

    fn handle_client_hello(&mut self, frame: &Frame, out: &mut Vec<SessionAction>) -> Result<(), CloseReason> {
        let hello: ClientHello = decode_control(frame, MessageKind::ClientHello)?;
        if hello.protocol_version != PROTOCOL_VERSION {
            return Err(CloseReason::ProtocolMismatch { client: hello.protocol_version, host: PROTOCOL_VERSION });
        }
        if hello.client_id.len() > MAX_IDENTIFIER_BYTES || hello.client_name.len() > MAX_IDENTIFIER_BYTES {
            return Err(CloseReason::MalformedHello);
        }
        let resume_source = parse_resume_source(hello.resume_source.as_ref())?;
        let peer_key = self.config.peer_public_key.clone().ok_or(CloseReason::NoPeerKey)?;
        let pinned = self.deps.pins.pin_for(&hello.client_id);
        if pinned.as_deref().is_some_and(|pin| !same_key(pin, &peer_key)) {
            return Err(CloseReason::ClientKeyMismatch { client_id: hello.client_id });
        }
        let already_paired = ClientHello::host_treats_as_paired(pinned.is_some(), hello.lost_pairing);

        self.client_id = hello.client_id;
        self.client_name = hello.client_name;
        self.peer_key = peer_key;
        out.push(SessionAction::Emit(HostEvent::ClientConnected {
            client_id: self.client_id.clone(),
            client_name: self.client_name.clone(),
            via_relay: self.config.arrived_through_relay,
        }));
        send_json(out, MessageKind::ServerHello, &self.server_hello(already_paired));

        if already_paired {
            self.authorize(resume_source, out);
            Ok(())
        } else {
            self.begin_pairing(out)
        }
    }

    /// The Mac addresses go out only to a paired client, since the hello precedes pairing and would otherwise
    /// hand them to any device on the LAN.
    fn server_hello(&self, already_paired: bool) -> ServerHello {
        ServerHello {
            server_id: self.config.host_id.clone(),
            host_name: self.config.host_name.clone(),
            protocol_version: PROTOCOL_VERSION,
            already_paired,
            mac_addresses: already_paired.then(|| self.config.mac_addresses.clone()),
            capabilities: ServerCapabilities { supports_video_pause: Some(true), ..ServerCapabilities::default() },
            agent_chat_agents: None,
        }
    }

    /// Only a paired client may move the capture source, so the resume is honoured here and nowhere else.
    fn authorize(&mut self, resume_source: Option<CaptureSource>, out: &mut Vec<SessionAction>) {
        if let Some(source) = resume_source {
            out.push(SessionAction::ForwardCommand(RemoteCommand::SetCaptureSource { source }));
        }
        self.deps.pins.mark_seen(&self.client_id, self.deps.clock.unix_seconds());
        self.state = HandshakeState::Ready;
        out.push(SessionAction::Authorized);
    }
}

fn parse_resume_source(value: Option<&Value>) -> Result<Option<CaptureSource>, CloseReason> {
    value
        .map(|value| serde_json::from_value(value.clone()))
        .transpose()
        .map_err(|_| CloseReason::MalformedHello)
}

/// Checks the kind and size before decoding, so an oversized or misrouted payload never reaches the parser.
pub(super) fn decode_control<T: DeserializeOwned>(frame: &Frame, kind: MessageKind) -> Result<T, CloseReason> {
    if frame.kind != kind {
        return Err(CloseReason::UnexpectedFrame(frame.kind));
    }
    if frame.payload.len() > MAX_CONTROL_PAYLOAD {
        return Err(CloseReason::MalformedPayload(kind));
    }
    serde_json::from_slice(&frame.payload).map_err(|_| CloseReason::MalformedPayload(kind))
}

pub(super) fn send_json<T: Serialize>(out: &mut Vec<SessionAction>, kind: MessageKind, value: &T) {
    // Protocol messages hold only strings, numbers, bools, options and byte arrays, which always serialise.
    let payload = serde_json::to_vec(value).expect("protocol messages always serialise to JSON");
    out.push(SessionAction::Send(Frame::new(kind, payload)));
}

/// Compares without an early exit on the first differing byte.
fn same_key(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |difference, (x, y)| difference | (x ^ y)) == 0
}

#[cfg(test)]
#[path = "handshake_tests.rs"]
mod tests;
