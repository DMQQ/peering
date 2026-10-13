//! What a session asks its caller to do. The state machine decides; the caller sends, shows and forwards.

use peering_wire::command::RemoteCommand;
use peering_wire::framing::{Frame, MessageKind};

#[derive(Debug, Clone, PartialEq)]
pub enum SessionAction {
    Send(Frame),
    Emit(HostEvent),
    /// The client may now receive catalogue, video and commands.
    Authorized,
    /// A frame on an authorised session, for the command dispatcher.
    ForwardFrame(Frame),
    ForwardCommand(RemoteCommand),
    /// The connection carries video. It needs an authorised control session for the same client.
    VideoConnection,
    RequestApproval { client_name: String },
    Close(CloseReason),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostEvent {
    ClientConnected {
        client_id: String,
        client_name: String,
        via_relay: bool,
    },
    PairingCode {
        code: String,
        secret: Vec<u8>,
        client_name: String,
        via_relay: bool,
    },
    PairingCompleted {
        client_name: String,
        accepted: bool,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CloseReason {
    UnexpectedFrame(MessageKind),
    MalformedPayload(MessageKind),
    ProtocolMismatch { client: u16, host: u16 },
    MalformedHello,
    NoPeerKey,
    ClientKeyMismatch { client_id: String },
    CommitmentMismatch,
    /// The client or the Mac refused the pairing. The refusal was already sent to the client.
    PairingRejected,
    PairingNotSaved,
}
