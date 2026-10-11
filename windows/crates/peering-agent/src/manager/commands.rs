//! What each request does to a chat: starting, prompting, answering, changing, closing and pausing it, and replaying
//! what it said.

use super::session::ManagedSession;
use super::{failed, no_chat, AgentSessionManager, AGENT_ID, MAXIMUM_PROMPT_BYTES};
use crate::claude_adapter::{ClaudeAdapter, ClaudeResume, ProcessLauncher, PERMISSION_MODES};
use peering_wire::agent::{
    AgentApprovalDecision, AgentEvent, AgentPermissionMode, AgentSessionState, AgentStreamPayload,
};
use std::path::{Path, PathBuf};

const PAUSE_NOTICE: &str = "Stopped and moved to history. Send a message to pick this chat up where it left off.";
const BUSY_TO_PAUSE: &str = "Stop the turn before moving this chat to history.";
const CANNOT_CONTINUE: &str = "That chat cannot be continued. Start a new one.";

impl<L: ProcessLauncher> AgentSessionManager<L> {
    pub(super) fn start(&mut self, agent_id: &str, directory: Option<&str>) -> Vec<AgentEvent> {
        if agent_id != AGENT_ID {
            return vec![failed(None, &format!("{agent_id} is not supported on this host yet."))];
        }
        let Some(directory) = directory else {
            return vec![failed(None, "Choose a folder to start the chat in.")];
        };
        // A relative folder would resolve against the host's own working directory.
        if !Path::new(directory).is_absolute() {
            return vec![failed(None, "That is not a folder this host can open.")];
        }
        let mut session = self.new_session(Path::new(directory));
        session.adapter.start(&mut self.launcher);
        let info = session.info();
        self.sessions.insert(session.id.clone(), session);
        vec![AgentEvent::Created { session: info }]
    }

    pub(super) fn prompt(&mut self, id: &str, text: &str) -> Vec<AgentEvent> {
        if !self.sessions.contains_key(id) {
            return vec![no_chat(id)];
        }
        if text.len() > MAXIMUM_PROMPT_BYTES {
            return vec![failed(Some(id), "That prompt is too long to send.")];
        }
        if text.trim().is_empty() {
            return Vec::new();
        }
        let Some(session) = self.ensure_live(id) else {
            return vec![failed(Some(id), CANNOT_CONTINUE)];
        };
        let mut events = vec![session.record(AgentStreamPayload::UserPrompt { text: text.to_owned() })];
        if !session.adapter.prompt(text) {
            events.push(failed(Some(id), "The agent did not take the prompt."));
        }
        events
    }

    pub(super) fn approval(&mut self, id: &str, approval_id: &str, decision: &AgentApprovalDecision) -> Vec<AgentEvent> {
        let Some(session) = self.sessions.get_mut(id) else {
            return vec![no_chat(id)];
        };
        // A late answer to an ask that is no longer waiting is ignored.
        if !session.pending_approvals.contains(approval_id) {
            return Vec::new();
        }
        let mut events = vec![session.record(AgentStreamPayload::ApprovalResolved {
            approval_id: approval_id.to_owned(),
            decision: decision.clone(),
        })];
        if !session.adapter.respond(approval_id, decision) {
            events.push(failed(Some(id), "The agent did not take the answer."));
        }
        events
    }

    pub(super) fn interrupt(&mut self, id: &str) -> Vec<AgentEvent> {
        let Some(session) = self.sessions.get_mut(id) else {
            return vec![no_chat(id)];
        };
        if session.adapter.is_running() {
            session.adapter.interrupt();
        }
        Vec::new()
    }

    pub(super) fn set_model(&mut self, id: &str, model: Option<&str>) -> Vec<AgentEvent> {
        if !self.sessions.contains_key(id) {
            return vec![no_chat(id)];
        }
        let Some(session) = self.ensure_live(id) else {
            return vec![failed(Some(id), CANNOT_CONTINUE)];
        };
        if session.adapter.set_model(model) {
            Vec::new()
        } else {
            vec![failed(Some(id), "The agent did not take the model change.")]
        }
    }

    pub(super) fn set_permission_mode(&mut self, id: &str, mode: AgentPermissionMode) -> Vec<AgentEvent> {
        if !self.sessions.contains_key(id) {
            return vec![no_chat(id)];
        }
        if !PERMISSION_MODES.contains(&mode) {
            return vec![failed(Some(id), "This agent cannot run in that mode.")];
        }
        let Some(session) = self.ensure_live(id) else {
            return vec![failed(Some(id), CANNOT_CONTINUE)];
        };
        if session.adapter.set_permission_mode(mode) {
            Vec::new()
        } else {
            vec![failed(Some(id), "The agent did not take the mode change.")]
        }
    }

    pub(super) fn close(&mut self, id: &str) -> Vec<AgentEvent> {
        let Some(mut session) = self.sessions.remove(id) else {
            return vec![no_chat(id)];
        };
        session.adapter.stop();
        vec![AgentEvent::Closed {
            session_id: id.to_owned(),
        }]
    }

    /// Stops the process and keeps the chat, so the next prompt picks it up again. A chat that has talked but never
    /// named its CLI session could not be picked up again, so it is not paused.
    pub(super) fn pause(&mut self, id: &str) -> Vec<AgentEvent> {
        let Some(session) = self.sessions.get_mut(id) else {
            return vec![no_chat(id)];
        };
        if session.is_busy() {
            return vec![failed(Some(id), BUSY_TO_PAUSE)];
        }
        if session.adapter.cli_session_id().is_none() && session.transcript.has_prompt() {
            return Vec::new();
        }
        let already_paused = matches!(
            session.transcript.last_payload(),
            Some(AgentStreamPayload::Notice { text }) if text == PAUSE_NOTICE
        );
        if !session.adapter.is_running() && already_paused {
            return Vec::new();
        }
        session.adapter.stop();
        vec![session.record(AgentStreamPayload::Notice {
            text: PAUSE_NOTICE.to_owned(),
        })]
    }

    /// The events after `since`, in chunks. The last chunk says so with `is_last`; an empty replay says so alone.
    pub(super) fn history(&self, id: &str, since: u64) -> Vec<AgentEvent> {
        let Some(session) = self.sessions.get(id) else {
            return vec![no_chat(id)];
        };
        let truncated_at_front = session.transcript.truncated_at_front();
        let chunks = session.transcript.chunks(since);
        if chunks.is_empty() {
            return vec![AgentEvent::Replay {
                session_id: id.to_owned(),
                events: Vec::new(),
                is_last: true,
                truncated_at_front,
            }];
        }
        let last = chunks.len() - 1;
        chunks
            .into_iter()
            .enumerate()
            .map(|(position, events)| AgentEvent::Replay {
                session_id: id.to_owned(),
                events,
                is_last: position == last,
                truncated_at_front,
            })
            .collect()
    }

    /// The chat with a live CLI, starting one that resumes its conversation if it has none. `None` for a chat that
    /// had a conversation and never learned its CLI session, since a new process would not remember it.
    pub(super) fn ensure_live(&mut self, id: &str) -> Option<&mut ManagedSession> {
        let launcher = &mut self.launcher;
        let session = self.sessions.get_mut(id)?;
        if !session.adapter.is_running() {
            if session.adapter.cli_session_id().is_none() && session.transcript.has_prompt() {
                return None;
            }
            revive(session, launcher);
        }
        Some(session)
    }
}

/// Starts a fresh adapter for `session`, resuming the CLI's conversation and the model and mode it had.
fn revive<L: ProcessLauncher>(session: &mut ManagedSession, launcher: &mut L) {
    let resume = ClaudeResume {
        cli_session_id: session.adapter.cli_session_id().map(str::to_owned),
        model: session.model.clone(),
        permission_mode: Some(session.permission_mode),
    };
    let mut adapter = ClaudeAdapter::new(PathBuf::from(&session.directory), resume);
    adapter.start(launcher);
    session.adapter = adapter;
    if matches!(session.state, AgentSessionState::Exited | AgentSessionState::Failed) {
        session.state = AgentSessionState::Idle;
    }
}
