//! Frames the session forwards once the client is authorised: commands, pings, file requests and agent requests.

use peering_core::session::dispatch::{on_ready_frame, DispatchContext, ReadyOutcome};
use peering_wire::agent::AgentRequest;
use peering_wire::command::RemoteCommand;
use peering_wire::framing::{Frame, MessageKind};

use super::connection::{Connection, Flow};
use super::video::CoordinatorControl;

impl Connection {
    pub(super) fn on_ready(&mut self, frame: &Frame) -> Flow {
        let (outcome, failure) = self.dispatch(|context| on_ready_frame(frame, context));
        if let Some(failure) = failure {
            self.send(error_frame("sourceUnavailable", &failure));
        }
        match outcome {
            ReadyOutcome::Dispatched(_) => Flow::Open,
            ReadyOutcome::Reply(reply) => {
                self.send(reply);
                Flow::Open
            }
            ReadyOutcome::Close(_) => Flow::Closed,
            ReadyOutcome::Unhandled(MessageKind::TerminalRequest) => self.terminal_request(frame),
            ReadyOutcome::Unhandled(MessageKind::AgentRequest) => self.agent_request(frame),
            ReadyOutcome::Unhandled(MessageKind::VideoKeyRequest) => self.answer_video_key(),
            ReadyOutcome::Unhandled(MessageKind::VideoTransport) => self.answer_video_transport(frame),
            ReadyOutcome::Unhandled(_) => Flow::Open,
        }
    }

    /// Runs a command the session resumed with; a capture source that could not be used is reported to the client.
    pub(super) fn dispatch_command(&mut self, command: RemoteCommand) {
        let ((), failure) = self.dispatch(|context| {
            peering_core::session::dispatch::dispatch(command, context);
        });
        if let Some(failure) = failure {
            self.send(error_frame("sourceUnavailable", &failure));
        }
    }

    /// Runs `dispatch` in the locked state. Returns the outcome and the capture failure, if any, so the caller sends
    /// after the lock is released.
    fn dispatch<T>(&self, run: impl FnOnce(&mut DispatchContext<'_>) -> T) -> (T, Option<String>) {
        let now = self.now();
        let mut guard = self.shared.lock();
        let state = &mut *guard;
        let transform = state.active_transform();
        let mut source = CoordinatorControl::new(&mut state.video, &mut state.system, now);
        let mut context = DispatchContext { observe_mode: false, transform, input: &mut state.input, source: &mut source };
        let outcome = run(&mut context);
        let failure = source.failure.take();
        (outcome, failure)
    }

    fn agent_request(&mut self, frame: &Frame) -> Flow {
        if !self.supports_agent_chat {
            return Flow::Open;
        }
        let Ok(request) = serde_json::from_slice::<AgentRequest>(&frame.payload) else {
            return Flow::Closed;
        };
        let manager = self
            .agent
            .get_or_insert_with(|| peering_agent::manager::AgentSessionManager::new(super::agent::StdLauncher));
        let events = manager.handle(request);
        for event in events {
            self.send_event(&event);
        }
        Flow::Open
    }
}

fn error_frame(code: &str, message: &str) -> Frame {
    let payload = serde_json::json!({ "code": code, "message": message });
    Frame::new(MessageKind::Error, serde_json::to_vec(&payload).expect("an error payload always serialises"))
}
