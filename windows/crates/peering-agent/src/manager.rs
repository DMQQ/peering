//! Agent chat sessions: which CLI each chat runs, what each chat has said, and the events a client is sent for a
//! request or a poll. Pure logic over `ClaudeAdapter`, so it runs with a fake process in tests.

mod clients;
mod commands;
mod session;
mod transcript;

#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_transcript;

use crate::claude_adapter::{ClaudeAdapter, ClaudeResume, ProcessLauncher};
use peering_wire::agent::{AgentEvent, AgentRequest, AgentStreamPayload};
pub use clients::ClientAgents;
use session::ManagedSession;
use std::collections::BTreeMap;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// The CLI a chat runs, and the name its binary is looked for under.
pub const AGENT_ID: &str = "claude";
const TITLE_PREFIX: &str = "Claude Code";
const MAXIMUM_PROMPT_BYTES: usize = 64 * 1024;
/// Seconds from the Unix epoch to 2001-01-01, the reference date the wire's times count from.
const UNIX_TO_REFERENCE_SECONDS: f64 = 978_307_200.0;
const NOT_SUPPORTED: &str = "This is not supported on this host yet.";

/// The agents a chat can be started with on this host.
pub fn agent_chat_agents() -> Vec<String> {
    vec![AGENT_ID.to_owned()]
}

pub struct AgentSessionManager<L: ProcessLauncher> {
    launcher: L,
    sessions: BTreeMap<String, ManagedSession>,
    started: u64,
}

impl<L: ProcessLauncher> AgentSessionManager<L> {
    pub fn new(launcher: L) -> Self {
        Self {
            launcher,
            sessions: BTreeMap::new(),
            started: 0,
        }
    }

    /// The events a request produces, in the order they should be sent.
    pub fn handle(&mut self, request: AgentRequest) -> Vec<AgentEvent> {
        match request {
            AgentRequest::List {} => vec![AgentEvent::Snapshot {
                sessions: self.sessions.values().map(ManagedSession::info).collect(),
            }],
            AgentRequest::History { session_id, since } => self.history(&session_id, since),
            AgentRequest::Start { agent_id, directory } => self.start(&agent_id, directory.as_deref()),
            AgentRequest::Prompt { session_id, text } => self.prompt(&session_id, &text),
            AgentRequest::Approval {
                session_id,
                approval_id,
                decision,
            } => self.approval(&session_id, &approval_id, &decision),
            AgentRequest::Interrupt { session_id } => self.interrupt(&session_id),
            AgentRequest::SetModel { session_id, model } => self.set_model(&session_id, model.as_deref()),
            AgentRequest::SetPermissionMode { session_id, mode } => self.set_permission_mode(&session_id, mode),
            AgentRequest::Close { session_id } => self.close(&session_id),
            AgentRequest::Pause { session_id } => self.pause(&session_id),
            AgentRequest::Changes { session_id }
            | AgentRequest::Commit { session_id, .. }
            | AgentRequest::Push { session_id } => vec![failed(Some(&session_id), NOT_SUPPORTED)],
            AgentRequest::Browse { .. } | AgentRequest::ListResumable {} | AgentRequest::Resume { .. } => {
                vec![failed(None, NOT_SUPPORTED)]
            }
        }
    }

    /// Reads what every running CLI has printed since the last poll.
    pub fn poll(&mut self) -> Vec<AgentEvent> {
        let mut events = Vec::new();
        for session in self.sessions.values_mut() {
            let payloads = session.adapter.poll();
            let turn_ended = payloads
                .iter()
                .any(|payload| matches!(payload, AgentStreamPayload::TurnFinished { .. }));
            for payload in payloads {
                events.push(session.record(payload));
            }
            events.extend(session.sync_facts(turn_ended));
        }
        events
    }

    fn new_session(&mut self, directory: &Path) -> ManagedSession {
        self.started += 1;
        let id = session_id(self.started);
        let folder = folder_name(directory);
        let title = unique_title(
            &format!("{TITLE_PREFIX} · {folder}"),
            self.sessions.values().map(|session| session.title.as_str()),
        );
        let adapter = ClaudeAdapter::new(directory.to_path_buf(), ClaudeResume::default());
        ManagedSession::new(id, title, directory, created_at(), adapter)
    }
}

fn session_id(number: u64) -> String {
    format!("00000000-0000-4000-8000-{number:012X}")
}

fn folder_name(directory: &Path) -> String {
    directory
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "/".to_owned())
}

/// Adds " 2", " 3" and so on until the title is not taken.
fn unique_title<'a>(base: &str, taken: impl Iterator<Item = &'a str> + Clone) -> String {
    let mut title = base.to_owned();
    let mut counter = 2;
    while taken.clone().any(|existing| existing == title) {
        title = format!("{base} {counter}");
        counter += 1;
    }
    title
}

/// Seconds since 2001-01-01, as the wire counts them.
fn created_at() -> f64 {
    let unix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs_f64())
        .unwrap_or(0.0);
    unix - UNIX_TO_REFERENCE_SECONDS
}

fn failed(session_id: Option<&str>, message: &str) -> AgentEvent {
    AgentEvent::Failed {
        session_id: session_id.map(str::to_owned),
        message: message.to_owned(),
    }
}

fn no_chat(session_id: &str) -> AgentEvent {
    failed(Some(session_id), "That chat is no longer here.")
}
