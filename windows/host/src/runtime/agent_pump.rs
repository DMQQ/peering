//! Delivers what the agent CLIs print. The managers belong to the host, not to a connection, so a chat keeps running while
//! its phone reconnects and the output goes to the client's newest connection.

use std::time::Duration;

use tokio::task::spawn_local;
use tokio::time::interval;

use super::shared::{HostState, Shared};
use super::video::{deliver, Outgoing};
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
                let payload = serde_json::to_vec(&event).expect("agent events always serialise");
                outgoing.push(Outgoing { to: slot.outbound.clone(), frame: Frame::new(MessageKind::AgentEvent, payload) });
            }
        }
        outgoing
    }
}

async fn run(shared: Shared) {
    let mut ticks = interval(POLL_INTERVAL);
    loop {
        ticks.tick().await;
        let outgoing = shared.lock().pump_agents();
        deliver(outgoing);
    }
}

pub fn spawn_pump(shared: Shared) {
    spawn_local(run(shared));
}
