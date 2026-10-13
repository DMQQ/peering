//! One chat as the manager holds it: its CLI, what it has said, and what it is doing.

use super::transcript::TranscriptLog;
use super::AGENT_ID;
use crate::claude_adapter::{ClaudeAdapter, PERMISSION_MODES};
use peering_wire::agent::{
    AgentEvent, AgentPermissionMode, AgentSessionInfo, AgentSessionState, AgentStreamPayload, AgentUsage,
};
use std::collections::BTreeSet;
use std::path::Path;

pub struct ManagedSession {
    pub id: String,
    pub title: String,
    pub directory: String,
    pub created_at: f64,
    pub adapter: ClaudeAdapter,
    pub transcript: TranscriptLog,
    pub state: AgentSessionState,
    pub pending_approvals: BTreeSet<String>,
    /// The facts the client last heard about. `sync_facts` compares them with the adapter and sends what changed.
    pub model: Option<String>,
    pub permission_mode: AgentPermissionMode,
    pub usage: Option<AgentUsage>,
}

impl ManagedSession {
    pub fn new(id: String, title: String, directory: &Path, created_at: f64, adapter: ClaudeAdapter) -> Self {
        Self {
            id,
            title,
            directory: directory.to_string_lossy().into_owned(),
            created_at,
            model: adapter.model().map(str::to_owned),
            permission_mode: adapter.permission_mode(),
            adapter,
            transcript: TranscriptLog::new(),
            state: AgentSessionState::Idle,
            pending_approvals: BTreeSet::new(),
            usage: None,
        }
    }

    pub fn info(&self) -> AgentSessionInfo {
        AgentSessionInfo {
            id: self.id.clone(),
            agent_id: AGENT_ID.to_owned(),
            title: self.title.clone(),
            directory: self.directory.clone(),
            state: self.state,
            last_index: self.transcript.last_index(),
            model: self.model.clone(),
            permission_mode: Some(self.permission_mode),
            permission_modes: Some(PERMISSION_MODES.to_vec()),
            model_choices: None,
            usage: self.usage.clone(),
            created_at: self.created_at,
        }
    }

    pub fn is_busy(&self) -> bool {
        matches!(self.state, AgentSessionState::Working | AgentSessionState::AwaitingApproval)
    }

    /// Logs one payload, moves the session's state with it, and returns the stream event to send.
    pub fn record(&mut self, payload: AgentStreamPayload) -> AgentEvent {
        self.update_state(&payload);
        let event = self.transcript.append(payload);
        AgentEvent::Stream {
            session_id: self.id.clone(),
            event,
        }
    }

    fn update_state(&mut self, payload: &AgentStreamPayload) {
        match payload {
            // The Claude stream never says a turn started, so the prompt that starts it does.
            AgentStreamPayload::UserPrompt { .. } => self.state = AgentSessionState::Working,
            AgentStreamPayload::ApprovalRequested { approval_id, .. } => {
                self.pending_approvals.insert(approval_id.clone());
                self.state = AgentSessionState::AwaitingApproval;
            }
            AgentStreamPayload::ApprovalResolved { approval_id, .. } => {
                self.pending_approvals.remove(approval_id);
                if self.pending_approvals.is_empty() && self.state == AgentSessionState::AwaitingApproval {
                    self.state = AgentSessionState::Working;
                }
            }
            AgentStreamPayload::TurnFinished { .. } => {
                self.pending_approvals.clear();
                self.state = AgentSessionState::Idle;
            }
            AgentStreamPayload::Failure { .. } => self.state = AgentSessionState::Failed,
            AgentStreamPayload::SessionExited { .. } => self.state = AgentSessionState::Exited,
            _ => {}
        }
    }

    /// Sends the model and mode when the adapter has them different from what the client last heard, and the usage
    /// when a turn has just ended.
    pub fn sync_facts(&mut self, turn_ended: bool) -> Vec<AgentEvent> {
        let mut events = Vec::new();
        if self.adapter.model() != self.model.as_deref() {
            self.model = self.adapter.model().map(str::to_owned);
            events.push(AgentEvent::ModelChanged {
                session_id: self.id.clone(),
                model: self.model.clone(),
            });
        }
        if self.adapter.permission_mode() != self.permission_mode {
            self.permission_mode = self.adapter.permission_mode();
            events.push(AgentEvent::PermissionModeChanged {
                session_id: self.id.clone(),
                mode: self.permission_mode,
            });
        }
        let usage = self.adapter.usage();
        if turn_ended && self.usage.as_ref() != Some(usage) {
            self.usage = Some(usage.clone());
            events.push(AgentEvent::UsageChanged {
                session_id: self.id.clone(),
                usage: usage.clone(),
            });
        }
        events
    }
}
