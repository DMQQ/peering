//! Delivers what the agent CLIs print. The managers belong to the host, not to a connection, so a chat keeps running while
//! its phone reconnects and the output goes to the client's newest connection.

use std::sync::Arc;
use std::time::Duration;

use tokio::task::{spawn_local, JoinHandle};
use tokio::time::interval;

use super::agent_gate;
use super::problem_source::ProblemSource;
use super::shared::{HostState, Shared};
use super::supervise::{record_problem, Pass, Supervised};
use super::video::{deliver, Outgoing};
use super::HostProfile;
use peering_agent::push::{AgentPush, Reach};
use peering_wire::agent::AgentEvent;
use peering_wire::framing::{Frame, MessageKind};
use peering_wire::relay_messages::RelayClientMessage;

const POLL_INTERVAL: Duration = Duration::from_millis(200);
/// How the pushes name the agent, as the Mac names Claude Code in its own.
const AGENT_NAME: &str = "Claude Code";

impl HostState {
    /// Reads every client's CLIs. An event for a client that is not connected is dropped: the chat's transcript keeps it,
    /// and `history` replays it when the phone returns.
    pub fn pump_agents(&mut self) -> Vec<Outgoing> {
        let events = self.agents.poll();
        let mut outgoing = Vec::new();
        for (client_id, event) in events {
            self.plan_agent_push(&client_id, &event);
            let newest = self.sessions.iter().filter(|(_, slot)| slot.client_id == client_id).max_by_key(|(id, _)| **id);
            if let Some((_, slot)) = newest.filter(|(_, slot)| agent_gate::admits(&event, &slot.client_flags)) {
                // Derived Serialize with string keys only: text from the CLI is just a string value, which cannot fail.
                let payload = serde_json::to_vec(&event).expect("agent events always serialise");
                outgoing.push(Outgoing { to: slot.outbound.clone(), frame: Frame::new(MessageKind::AgentEvent, payload) });
            }
        }
        outgoing
    }
}

impl HostState {
    /// Queues the push an event calls for, when the phone that owns the chat registered a token. The relay carries it once the
    /// host is registered with it.
    fn plan_agent_push(&mut self, client_id: &str, event: &AgentEvent) {
        let AgentEvent::Stream { session_id, event } = event else {
            return;
        };
        let token = self.terminals.push_token_for(client_id);
        let foreground = self.sessions.values().any(|slot| slot.client_id == client_id && !slot.background);
        let reach = Reach { has_token: token.is_some(), foreground };
        let Some(push) = self.agent_pushes.observe(session_id, &event.payload, AGENT_NAME, reach) else {
            return;
        };
        if let Some(token) = token {
            self.notifications.hold(push_message(token, push));
        }
    }
}

/// The relay message that carries a chat's push. A tap on a button comes back with the ids it names.
fn push_message(device_token: String, push: AgentPush) -> RelayClientMessage {
    let (category, session_id, approval_id) = match push.action {
        Some(action) => (Some(action.category.to_owned()), Some(action.session_id), Some(action.approval_id)),
        None => (None, None, None),
    };
    RelayClientMessage::NotifyDevice { device_token, title: push.title, body: push.body, source: None, category, session_id, approval_id }
}

/// One supervised pass: a panic in `poll` is caught and shown as a problem, and the loop is held off, instead of ending the
/// host.
pub(super) fn supervised_pass(
    supervised: &mut Supervised,
    shared: &Shared,
    source: ProblemSource,
    now: f64,
    pass: impl FnOnce(&mut HostState) -> Vec<Outgoing>,
) -> Vec<Outgoing> {
    let result = supervised.run(now, || pass(&mut shared.lock()), |text| record_problem(shared, source, text));
    match result {
        Pass::Done(outgoing) => outgoing,
        Pass::Skipped | Pass::Panicked => Vec::new(),
    }
}

async fn run(shared: Shared, profile: Arc<HostProfile>) {
    let mut ticks = interval(POLL_INTERVAL);
    let mut supervised = Supervised::new("agents");
    loop {
        ticks.tick().await;
        let now = profile.clock.now_seconds();
        deliver(supervised_pass(&mut supervised, &shared, ProblemSource::Agents, now, HostState::pump_agents));
    }
}

pub fn spawn_pump(shared: Shared, profile: Arc<HostProfile>) -> JoinHandle<()> {
    spawn_local(run(shared, profile))
}

#[cfg(test)]
mod tests {
    use super::super::test_support::runtime;
    use super::*;

    fn shared() -> Shared {
        runtime().shared
    }

    fn registered(state: &mut HostState, client: &str) {
        let request = peering_wire::terminal::TerminalRequest::RegisterPushToken { token: vec![0xAB, 0xCD] };
        state.terminals.handle(client, &request);
    }

    fn stream(payload: peering_wire::agent::AgentStreamPayload) -> AgentEvent {
        AgentEvent::Stream { session_id: "chat".to_owned(), event: peering_wire::agent::AgentStreamEvent { index: 1, payload } }
    }

    fn approval_request() -> AgentEvent {
        let call = peering_wire::agent::AgentToolCall {
            id: "c".to_owned(),
            name: "Bash".to_owned(),
            title: "Bash".to_owned(),
            detail: Some("cargo test".to_owned()),
            file_path: None,
            diff: None,
            questions: None,
            plan: None,
        };
        stream(peering_wire::agent::AgentStreamPayload::ApprovalRequested { approval_id: "a1".to_owned(), call, reason: None })
    }

    #[test]
    fn an_approval_for_a_phone_with_a_token_is_queued_for_the_relay() {
        let shared = shared();
        let mut state = shared.lock();
        registered(&mut state, "phone");
        state.plan_agent_push("phone", &approval_request());
        let Some(RelayClientMessage::NotifyDevice { device_token, title, body, category, session_id, approval_id, .. }) = state.notifications.next()
        else {
            panic!("a push is waiting");
        };
        assert_eq!(device_token, "abcd");
        assert_eq!((title.as_str(), body.as_str()), ("Claude Code asks", "cargo test"));
        assert_eq!(category.as_deref(), Some("peering.agent.approval.tool"));
        assert_eq!((session_id.as_deref(), approval_id.as_deref()), (Some("chat"), Some("a1")));
    }

    #[test]
    fn a_phone_with_no_token_is_not_pushed_to() {
        let shared = shared();
        let mut state = shared.lock();
        state.plan_agent_push("phone", &approval_request());
        assert_eq!(state.notifications.next(), None);
    }

    #[test]
    fn a_finished_turn_is_pushed_only_while_the_phone_is_away() {
        let shared = shared();
        let mut state = shared.lock();
        registered(&mut state, "phone");
        let done = stream(peering_wire::agent::AgentStreamPayload::TurnFinished {
            summary: peering_wire::agent::AgentTurnSummary {
                ok: true,
                stopped: false,
                cost_usd: None,
                input_tokens: None,
                output_tokens: None,
                duration: None,
                model: None,
            },
        });
        state.sessions.insert(1, super::super::test_support::slot("phone"));
        state.plan_agent_push("phone", &done);
        assert_eq!(state.notifications.next(), None, "the app is open and shows it");
        state.sessions.get_mut(&1).expect("the session").background = true;
        state.plan_agent_push("phone", &done);
        let Some(RelayClientMessage::NotifyDevice { title, category, approval_id, .. }) = state.notifications.next() else {
            panic!("a push is waiting");
        };
        assert_eq!(title, "Claude Code finished");
        assert_eq!((category.as_deref(), approval_id.as_deref()), (Some("peering.agent.finished"), Some("")));
    }

    #[test]
    fn events_that_are_not_live_stream_output_push_nothing() {
        let shared = shared();
        let mut state = shared.lock();
        registered(&mut state, "phone");
        state.plan_agent_push("phone", &AgentEvent::Closed { session_id: "chat".to_owned() });
        assert_eq!(state.notifications.next(), None);
    }

    #[test]
    fn a_panic_in_the_agent_pass_is_a_problem_and_the_next_pass_clears_it() {
        let shared = shared();
        let mut supervised = Supervised::new("agents");
        let none = supervised_pass(&mut supervised, &shared, ProblemSource::Agents, 1.0, |_| panic!("the adapter broke"));
        assert!(none.is_empty());
        assert!(shared.lock().problems.get(&ProblemSource::Agents).is_some_and(|text| text.contains("the adapter broke")));

        let held_off = supervised_pass(&mut supervised, &shared, ProblemSource::Agents, 1.1, |_| panic!("must not run inside the backoff"));
        assert!(held_off.is_empty());

        let _ = supervised_pass(&mut supervised, &shared, ProblemSource::Agents, 2.0, |_| Vec::new());
        assert!(!shared.lock().problems.contains_key(&ProblemSource::Agents));
    }
}
