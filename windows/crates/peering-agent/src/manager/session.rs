//! One chat as the manager holds it: its CLI, what it has said, and what it is doing.

use super::transcript::TranscriptLog;
use crate::adapter::AgentAdapter;
use peering_wire::agent::{
    AgentEvent, AgentPermissionMode, AgentSessionInfo, AgentSessionState, AgentStreamPayload, AgentUsage,
};
use std::collections::BTreeSet;
use std::path::Path;

pub struct ManagedSession {
    pub id: String,
    pub agent_id: String,
    pub title: String,
    pub directory: String,
    pub created_at: f64,
    pub adapter: AgentAdapter,
    pub model_choices: Option<Vec<String>>,
    pub transcript: TranscriptLog,
    pub state: AgentSessionState,
    pub pending_approvals: BTreeSet<String>,
    /// The facts the client last heard about. `sync_facts` compares them with the adapter and sends what changed.
    pub model: Option<String>,
    pub permission_mode: AgentPermissionMode,
    pub usage: Option<AgentUsage>,
    /// Whether a finished turn is pushed to the phone whatever the phone is doing (`Some(true)`), never (`Some(false)`), or by
    /// the phone's own presence (`None`). A routine's chat decides it; a chat the phone started leaves it `None`.
    pub finish_alert: Option<bool>,
    /// How the last turn ended, `None` while none has.
    pub last_turn_ok: Option<bool>,
}

impl ManagedSession {
    pub fn new(id: String, agent_id: &str, title: String, directory: &Path, created_at: f64, adapter: AgentAdapter) -> Self {
        Self {
            id,
            agent_id: agent_id.to_owned(),
            model_choices: None,
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
            finish_alert: None,
            last_turn_ok: None,
        }
    }

    pub fn info(&self) -> AgentSessionInfo {
        AgentSessionInfo {
            id: self.id.clone(),
            agent_id: self.agent_id.clone(),
            title: self.title.clone(),
            directory: self.directory.clone(),
            state: self.state,
            last_index: self.transcript.last_index(),
            model: self.model.clone(),
            permission_mode: Some(self.permission_mode),
            permission_modes: Some(self.adapter.permission_modes().to_vec()),
            model_choices: self.model_choices.clone(),
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
            // Claude's stream never says a turn started, so the prompt that starts it does.
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
            AgentStreamPayload::TurnFinished { summary } => {
                self.last_turn_ok = Some(summary.ok && !summary.stopped);
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
