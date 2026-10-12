//! Delivers what the agent CLIs print. The managers belong to the host, not to a connection, so a chat keeps running while
//! its phone reconnects and the output goes to the client's newest connection.

use std::sync::Arc;
use std::time::Duration;

use tokio::task::{spawn_local, JoinHandle};
use tokio::time::interval;

use super::shared::{HostState, Shared};
use super::supervise::{record_problem, Pass, Supervised};
use super::video::{deliver, Outgoing};
use super::HostProfile;
use peering_wire::framing::{Frame, MessageKind};

const POLL_INTERVAL: Duration = Duration::from_millis(200);

impl HostState {
    /// Reads every client's CLIs. An event for a client that is not connected is dropped: the chat's transcript keeps it,
    /// and `history` replays it when the phone returns.
    pub fn pump_agents(&mut self) -> Vec<Outgoing> {
        let events = self.agents.poll();
        let mut outgoing = Vec::new();
        for (client_id, event) in events {
            let newest = self.sessions.iter().filter(|(_, slot)| slot.client_id == client_id).max_by_key(|(id, _)| **id);
            if let Some((_, slot)) = newest {
                // Derived Serialize with string keys only: text from the CLI is just a string value, which cannot fail.
                let payload = serde_json::to_vec(&event).expect("agent events always serialise");
                outgoing.push(Outgoing { to: slot.outbound.clone(), frame: Frame::new(MessageKind::AgentEvent, payload) });
            }
        }
        outgoing
    }
}

/// One supervised pass: a panic in `poll` is caught and shown as a problem, and the loop is held off, instead of ending the
/// host.
fn supervised_pass(
    supervised: &mut Supervised,
    shared: &Shared,
    now: f64,
    pass: impl FnOnce(&mut HostState) -> Vec<Outgoing>,
) -> Vec<Outgoing> {
    let result = supervised.run(now, || pass(&mut shared.lock()), |text| record_problem(shared, "agents", text));
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
        deliver(supervised_pass(&mut supervised, &shared, now, HostState::pump_agents));
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

    #[test]
    fn a_panic_in_the_agent_pass_is_a_problem_and_the_next_pass_clears_it() {
        let shared = shared();
        let mut supervised = Supervised::new("agents");
        let none = supervised_pass(&mut supervised, &shared, 1.0, |_| panic!("the adapter broke"));
        assert!(none.is_empty());
        assert!(shared.lock().problems.get("agents").is_some_and(|text| text.contains("the adapter broke")));

        let held_off = supervised_pass(&mut supervised, &shared, 1.1, |_| panic!("must not run inside the backoff"));
        assert!(held_off.is_empty());

        let _ = supervised_pass(&mut supervised, &shared, 2.0, |_| Vec::new());
        assert!(shared.lock().problems.get("agents").is_none());
    }
}
