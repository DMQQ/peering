//! The chats routines run in: started like a phone's own, titled after the routine, and read back for how the run went.

use super::{unique_title, AgentSessionManager};
use crate::adapter::AgentResume;
use crate::claude_adapter::ProcessLauncher;
use crate::routines::ChatStatus;
use peering_wire::agent::{AgentEvent, AgentRoutine};
use std::path::Path;

impl<L: ProcessLauncher> AgentSessionManager<L> {
    /// Creates the chat and sends the routine's prompt. The events are the chat's announcement and the prompt's own.
    pub fn start_routine_chat(&mut self, routine: &AgentRoutine) -> Result<(String, Vec<AgentEvent>), String> {
        let resume = AgentResume { permission_mode: Some(routine.permission_mode), ..AgentResume::default() };
        let Some(mut session) = self.new_session(&routine.agent_id, Path::new(&routine.directory), resume) else {
            return Err("This PC no longer has that agent.".to_owned());
        };
        session.title = unique_title(&routine.name, self.sessions.values().map(|existing| existing.title.as_str()));
        session.finish_alert = Some(routine.notifies_when_done.unwrap_or(true));
        session.adapter.start(&mut self.launcher);
        let id = session.id.clone();
        let mut events = vec![AgentEvent::Created { session: session.info() }];
        self.sessions.insert(id.clone(), session);
        events.extend(self.prompt(&id, &routine.prompt));
        Ok((id, events))
    }

    /// The chat's state and how its last turn ended. A `None` state is a chat that is gone.
    pub fn routine_chat_status(&self, session_id: &str) -> ChatStatus {
        match self.sessions.get(session_id) {
            Some(session) => ChatStatus { state: Some(session.state), finished_ok: session.last_turn_ok },
            None => ChatStatus { state: None, finished_ok: None },
        }
    }

    /// Whether a finished turn of this chat is pushed whatever the phone is doing; see `ManagedSession::finish_alert`.
    pub fn finish_alert_of(&self, session_id: &str) -> Option<bool> {
        self.sessions.get(session_id)?.finish_alert
    }
}
