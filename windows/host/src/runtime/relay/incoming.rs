//! What the relay's socket delivers: answers to the video lanes' address asks, and the registration's own messages.

use peering_core::ports::clock::Clock;
use peering_core::relay::registration::{RegAction, RelayRegistration};
use peering_wire::relay_messages::RelayServerMessage;
use tokio_tungstenite::tungstenite::Message;

use super::{set_relay_status, RelayStatus};
use crate::runtime::peer_address::peer_socket_addr;
use crate::runtime::problem_source::ProblemSource;
use crate::runtime::shared::Shared;

/// What a read from the relay's socket asks of the loop.
pub(super) enum Incoming {
    Closed,
    Actions(Vec<RegAction>),
    Nothing,
}

type SocketRead = Option<Result<Message, tokio_tungstenite::tungstenite::Error>>;

pub(super) fn on_socket_message(message: SocketRead, registration: &mut RelayRegistration, shared: &Shared, clock: &dyn Clock) -> Incoming {
    match message {
        Some(Ok(Message::Text(text))) => {
            registration.note_frame(clock);
            on_relay_text(&text, registration, shared, clock).map_or(Incoming::Nothing, Incoming::Actions)
        }
        Some(Ok(Message::Close(_))) | None | Some(Err(_)) => Incoming::Closed,
        // Pings, pongs and binary frames carry nothing for the registration but prove the socket is alive.
        Some(Ok(_)) => {
            registration.note_frame(clock);
            Incoming::Nothing
        }
    }
}

/// A text message from the relay: an answer for a video lane, which goes to that lane, or a registration message. Returns the
/// registration's next actions, or `None` when the message was an answer or not one the relay protocol has.
fn on_relay_text(text: &str, registration: &mut RelayRegistration, shared: &Shared, clock: &dyn Clock) -> Option<Vec<RegAction>> {
    let message = serde_json::from_str::<RelayServerMessage>(text).ok()?;
    if answer_ask(shared, &message) {
        return None;
    }
    let actions = registration.on_message(message, clock);
    if registration.is_registered() {
        set_relay_status(shared, RelayStatus::Registered);
        shared.lock().clear_problem(ProblemSource::RelayClock);
    }
    Some(actions)
}

/// Hands the relay's answer to a video lane's `requestPeerAddress` to that lane. Returns true when the message was such an
/// answer, which must not reach the registration: the registration treats any error as a reason to disconnect.
fn answer_ask(shared: &Shared, message: &RelayServerMessage) -> bool {
    match message {
        RelayServerMessage::PeerAddress { host, port } => {
            if let Some(address) = peer_socket_addr(host, *port) {
                shared.peer_addresses().answer(address);
            }
            true
        }
        RelayServerMessage::Error { code, .. } if code == "peerAddressUnknown" => {
            shared.peer_addresses().refuse();
            true
        }
        _ => false,
    }
}
