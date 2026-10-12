//! One agent manager per client, kept for the life of the host. A phone that reconnects finds its chats and the CLIs
//! behind them still running, as it does on the Mac.

use std::collections::BTreeMap;

use peering_wire::agent::{AgentEvent, AgentRequest};

use super::AgentSessionManager;
use crate::claude_adapter::ProcessLauncher;

pub struct ClientAgents<L: ProcessLauncher> {
    managers: BTreeMap<String, AgentSessionManager<L>>,
    new_launcher: Box<dyn FnMut() -> L>,
}

impl<L: ProcessLauncher> ClientAgents<L> {
    pub fn new(new_launcher: impl FnMut() -> L + 'static) -> Self {
        Self { managers: BTreeMap::new(), new_launcher: Box::new(new_launcher) }
    }

    /// The events `request` produces for `client_id`, starting that client's manager on first use.
    pub fn handle(&mut self, client_id: &str, request: AgentRequest) -> Vec<AgentEvent> {
        let launcher = &mut self.new_launcher;
        self.managers
            .entry(client_id.to_owned())
            .or_insert_with(|| AgentSessionManager::new(launcher()))
            .handle(request)
    }

    /// What every client's CLIs printed since the last poll, each event with the client it belongs to.
    pub fn poll(&mut self) -> Vec<(String, AgentEvent)> {
        let mut events = Vec::new();
        for (client_id, manager) in &mut self.managers {
            events.extend(manager.poll().into_iter().map(|event| (client_id.clone(), event)));
        }
        events
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::claude_adapter::fake::{shared_script, ScriptedLauncher};
    use peering_wire::agent::AgentSessionInfo;

    fn agents() -> ClientAgents<ScriptedLauncher> {
        let script = shared_script();
        ClientAgents::new(move || ScriptedLauncher::new(&script))
    }

    fn start(agents: &mut ClientAgents<ScriptedLauncher>, client: &str) -> String {
        let events = agents.handle(
            client,
            AgentRequest::Start { agent_id: "claude".to_owned(), directory: Some("/work/project".to_owned()) },
        );
        let [AgentEvent::Created { session }] = events.as_slice() else {
            panic!("expected created, got {events:?}");
        };
        session.id.clone()
    }

    fn listed(agents: &mut ClientAgents<ScriptedLauncher>, client: &str) -> Vec<AgentSessionInfo> {
        match agents.handle(client, AgentRequest::List {}).as_slice() {
            [AgentEvent::Snapshot { sessions }] => sessions.clone(),
            other => panic!("expected a snapshot, got {other:?}"),
        }
    }

    #[test]
    fn a_client_that_asks_again_finds_the_chat_it_started() {
        let mut agents = agents();
        let id = start(&mut agents, "phone-a");
        let sessions = listed(&mut agents, "phone-a");
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].id, id);
    }

    #[test]
    fn one_clients_chats_are_not_listed_to_another() {
        let mut agents = agents();
        start(&mut agents, "phone-a");
        assert!(listed(&mut agents, "phone-b").is_empty());
    }

    #[test]
    fn each_client_numbers_its_own_chats() {
        let mut agents = agents();
        assert_eq!(start(&mut agents, "phone-a"), start(&mut agents, "phone-b"));
    }

    #[test]
    fn a_poll_with_nothing_running_yields_no_events() {
        let mut agents = agents();
        assert!(agents.poll().is_empty());
        start(&mut agents, "phone-a");
        assert!(agents.poll().iter().all(|(client, _)| client == "phone-a"));
    }
}
