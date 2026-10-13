//! Frames the session forwards once the client is authorised: commands, pings, file requests and agent requests.

use peering_core::session::dispatch::{on_ready_frame, DispatchContext, DispatchOutcome, IgnoreReason, ReadyOutcome};
use peering_core::video::intent::VideoIntent;
use peering_wire::agent::AgentRequest;
use peering_wire::command::RemoteCommand;
use peering_wire::framing::{Frame, MessageKind};
use peering_wire::handshake::ClientStatePayload;

use super::agent_browse;
use super::hooks;
use super::refusal::{notice_for, preview_refusal, source_unavailable, Refusal};
use super::connection::{Connection, Flow};
use super::video::CoordinatorControl;

impl Connection {
    pub(super) fn on_ready(&mut self, frame: &Frame) -> Flow {
        let (outcome, failure) = self.dispatch(|context| on_ready_frame(frame, context));
        if let Some(failure) = failure {
            self.report_source_failure(&failure);
        }
        match outcome {
            ReadyOutcome::Dispatched(DispatchOutcome::Applied) => Flow::Open,
            ReadyOutcome::Dispatched(DispatchOutcome::Ignored(reason)) => {
                self.refuse(reason);
                Flow::Open
            }
            ReadyOutcome::Dispatched(DispatchOutcome::ForHost(command)) => {
                self.host_command(command);
                Flow::Open
            }
            ReadyOutcome::Reply(reply) => {
                self.send(reply);
                Flow::Open
            }
            ReadyOutcome::Close(_) => Flow::Closed,
            ReadyOutcome::Unhandled(MessageKind::TerminalRequest) => self.terminal_request(frame),
            ReadyOutcome::Unhandled(MessageKind::AgentRequest) => self.agent_request(frame),
            ReadyOutcome::Unhandled(MessageKind::VideoKeyRequest) => self.answer_video_key(),
            ReadyOutcome::Unhandled(MessageKind::VideoTransport) => self.answer_video_transport(frame),
            ReadyOutcome::Unhandled(MessageKind::ClientState) => self.client_state(frame),
            ReadyOutcome::Unhandled(MessageKind::VideoChunk) => self.clipboard_chunk(frame),
            ReadyOutcome::Unhandled(MessageKind::PreviewRequest) => {
                if let Some(refusal) = preview_refusal(&frame.payload) {
                    self.send(refusal);
                }
                Flow::Open
            }
            // Read and set aside: the host never declares supportsLiveActivityPush, and a stray token is not an error.
            ReadyOutcome::Unhandled(_) => Flow::Open,
        }
    }

    /// Runs a command the session resumed with; a capture source that could not be used is reported to the client.
    pub(super) fn dispatch_command(&mut self, command: RemoteCommand) {
        let ((), failure) = self.dispatch(|context| {
            peering_core::session::dispatch::dispatch(command, context);
        });
        if let Some(failure) = failure {
            self.report_source_failure(&failure);
        }
    }

    /// A capture source that could not be used. A notice that lapses, because an `error` frame would end an iPhone session.
    pub(super) fn report_source_failure(&self, failure: &str) {
        let now = self.now();
        self.shared.lock().refusal = Some(Refusal::until(source_unavailable(failure), now));
    }

    /// Tells the phone that a command it sent is one this host does not carry out.
    fn refuse(&self, reason: IgnoreReason) {
        if let Some(notice) = notice_for(reason) {
            let now = self.now();
            self.shared.lock().refusal = Some(Refusal::until(notice, now));
        }
    }

    /// Runs `dispatch` in the locked state. Returns the outcome and the capture failure, if any, so the caller sends
    /// after the lock is released.
    pub(super) fn dispatch<T>(&self, run: impl FnOnce(&mut DispatchContext<'_>) -> T) -> (T, Option<String>) {
        let now = self.now();
        let mut guard = self.shared.lock();
        let state = &mut *guard;
        let transform = state.active_transform();
        let mut source = CoordinatorControl::new(&state.video, &mut state.system, now);
        let mut tracked = state.hold.track(self.session_id, &mut state.input);
        let mut context = DispatchContext { observe_mode: false, transform, input: &mut tracked, source: &mut source };
        let outcome = run(&mut context);
        let failure = source.failure.take();
        (outcome, failure)
    }

    /// A malformed report is ignored: it only changes how long the phone may stay silent and whether it is sent video.
    fn client_state(&mut self, frame: &Frame) -> Flow {
        let Ok(report) = serde_json::from_slice::<ClientStatePayload>(&frame.payload) else {
            return Flow::Open;
        };
        self.liveness.set_background(report.background);
        let mut guard = self.shared.lock();
        let state = &mut *guard;
        if let Some(slot) = state.sessions.get_mut(&self.session_id) {
            slot.background = report.background;
        }
        if !report.background {
            state.video.request(VideoIntent::Resync);
        }
        state.refresh_watched();
        Flow::Open
    }

    /// An approval for a Claude Code hook in a terminal belongs to the hook broker, not to a chat. The broker is asked first, as
    /// the Mac host asks its external approvals, because a hook has no chat to belong to.
    fn answered_by_a_hook(&self, request: &AgentRequest) -> bool {
        let AgentRequest::Approval { approval_id, decision, .. } = request else {
            return false;
        };
        let broker = self.shared.lock().hook_broker.clone();
        broker.is_some_and(|broker| broker.resolve(approval_id, hooks::answer_of(decision)))
    }

    fn agent_request(&mut self, frame: &Frame) -> Flow {
        let Ok(request) = serde_json::from_slice::<AgentRequest>(&frame.payload) else {
            return Flow::Closed;
        };
        if self.answered_by_a_hook(&request) || self.client_flags.supports_agent_chat != Some(true) {
            return Flow::Open;
        }
        if let AgentRequest::Browse { path } = request {
            let browser = self.shared.lock().agent_browser.clone();
            agent_browse::answer(browser, path, self.outbound.clone());
            return Flow::Open;
        }
        let client_id = self.session.client_id().to_owned();
        let events = self.shared.lock().agents.handle(&client_id, request);
        for event in events {
            self.send_event(&event);
        }
        Flow::Open
    }
}
