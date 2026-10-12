//! Applying what the core's session asks for: sending a frame, telling the pairing service, registering, or closing.

use peering_core::session::actions::SessionAction;
use peering_wire::framing::{Frame, MessageKind};
use peering_wire::handshake::ServerHello;

use super::{Connection, Flow};

impl Connection {
    pub(super) fn apply_all(&mut self, actions: Vec<SessionAction>) -> Flow {
        for action in actions {
            if self.apply(action) == Flow::Closed {
                return Flow::Closed;
            }
        }
        Flow::Open
    }

    fn apply(&mut self, action: SessionAction) -> Flow {
        match action {
            SessionAction::Send(frame) => self.send(self.decorate(frame)),
            SessionAction::Emit(event) => {
                let now = self.now();
                self.shared.lock().pairing.apply_event(self.session_id, &event, now);
            }
            SessionAction::Authorized => self.register(),
            SessionAction::ForwardFrame(frame) => return self.on_ready(&frame),
            SessionAction::ForwardCommand(command) => self.dispatch_command(command),
            SessionAction::VideoConnection => {
                self.pre_auth = None;
                return self.attach_video();
            }
            SessionAction::RequestApproval { client_name } => {
                let refused = self.shared.lock().pairing.request_approval(self.session_id, &client_name).err();
                if let Some(decision) = refused {
                    // This connection hears its own refusal on the approvals channel and answers the client.
                    let _delivered = self.shared.approvals.send(decision);
                }
            }
            SessionAction::Close(_) => return Flow::Closed,
        }
        Flow::Open
    }

    pub(in super::super) fn send(&self, frame: Frame) {
        // A writer that has stopped ends this connection on its next read, so a failed send needs no handling here.
        let _queued = self.outbound.send(frame);
    }

    pub(in super::super) fn send_event<T: serde::Serialize>(&self, event: &T) {
        // Derived Serialize with string keys only: text from the CLI is just a string value, which cannot fail.
        self.send(Frame::new(MessageKind::AgentEvent, serde_json::to_vec(event).expect("agent events always serialise")));
    }

    /// The host decorates its own hello with the services it runs, so the client sees what this build can do.
    fn decorate(&self, frame: Frame) -> Frame {
        if frame.kind != MessageKind::ServerHello {
            return frame;
        }
        let Ok(mut hello) = serde_json::from_slice::<ServerHello>(&frame.payload) else {
            return frame;
        };
        let agent_installed = self.shared.lock().agent_availability.installed(self.now());
        if agent_installed {
            hello.capabilities.supports_agent_chat = Some(true);
            hello.capabilities.supports_agent_list = Some(true);
            hello.agent_chat_agents = Some(peering_agent::manager::agent_chat_agents());
        }
        hello.capabilities.supports_file_browser = Some(true);
        if self.profile.can_lock_screen {
            hello.capabilities.supports_lock_screen = Some(true);
        }
        // The hello was decoded from our own derived type a moment ago, so writing it back cannot fail.
        Frame::new(MessageKind::ServerHello, serde_json::to_vec(&hello).expect("a hello always serialises"))
    }
}
