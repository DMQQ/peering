//! Agent chat sessions: which CLI each chat runs, what each chat has said, and the events a client is sent for a
//! request or a poll. Pure logic over `AgentAdapter`, so it runs with a fake process in tests.

mod clients;
mod commands;
mod fit;
mod session;
mod transcript;

#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_transcript;

use crate::adapter::{agent_name, AgentAdapter, AgentResume, AGENTS};
use crate::claude_adapter::ProcessLauncher;
use crate::codex_session_log;
use peering_wire::agent::{AgentEvent, AgentRequest, AgentStreamPayload};
pub use clients::ClientAgents;
use session::ManagedSession;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const MAXIMUM_PROMPT_BYTES: usize = 64 * 1024;
/// Seconds from the Unix epoch to 2001-01-01, the reference date the wire's times count from.
const UNIX_TO_REFERENCE_SECONDS: f64 = 978_307_200.0;
const NOT_SUPPORTED: &str = "This is not supported on this host yet.";

/// Every agent a chat can be started with on this host, installed or not.
pub fn agent_chat_agents() -> Vec<String> {
    AGENTS.iter().map(|(id, _)| (*id).to_owned()).collect()
}

pub struct AgentSessionManager<L: ProcessLauncher> {
    launcher: L,
    sessions: BTreeMap<String, ManagedSession>,
    started: u64,
    /// Codex's own folder (`CODEX_HOME` or `.codex`), where its thread logs and model list are.
    codex_home: Option<PathBuf>,
}

impl<L: ProcessLauncher> AgentSessionManager<L> {
    pub fn new(launcher: L) -> Self {
        Self {
            launcher,
            sessions: BTreeMap::new(),
            started: 0,
            codex_home: None,
        }
    }

    pub fn set_codex_home(&mut self, codex_home: PathBuf) {
        self.codex_home = Some(codex_home);
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

    /// The folder a chat runs in, for the git review that works on it.
    pub fn directory_of(&self, session_id: &str) -> Option<&str> {
        self.sessions.get(session_id).map(|session| session.directory.as_str())
    }

    /// Reads what every running CLI has printed since the last poll.
    pub fn poll(&mut self) -> Vec<AgentEvent> {
        let mut events = Vec::new();
        for session in self.sessions.values_mut() {
            let payloads = session.adapter.poll(&mut self.launcher);
            let turn_ended = session.adapter.take_usage_due()
                || payloads
                    .iter()
                    .any(|payload| matches!(payload, AgentStreamPayload::TurnFinished { .. }));
            for payload in payloads {
                events.push(session.record(payload));
            }
            events.extend(session.sync_facts(turn_ended));
        }
        events
    }

    /// `None` for an agent this host does not know.
    fn new_session(&mut self, agent_id: &str, directory: &Path) -> Option<ManagedSession> {
        let name = agent_name(agent_id)?;
        let adapter = self.make_adapter(agent_id, directory, AgentResume::default())?;
        self.started += 1;
        let id = session_id(self.started);
        let folder = folder_name(directory);
        let title = unique_title(
            &format!("{name} · {folder}"),
            self.sessions.values().map(|session| session.title.as_str()),
        );
        let mut session = ManagedSession::new(id, agent_id, title, directory, created_at(), adapter);
        session.model_choices = self.model_choices(agent_id);
        Some(session)
    }

    fn make_adapter(&self, agent_id: &str, directory: &Path, resume: AgentResume) -> Option<AgentAdapter> {
        let sessions = self.codex_home.as_ref().map(|home| home.join("sessions"));
        AgentAdapter::make(agent_id, directory, resume, sessions.as_deref())
    }

    /// Codex lists its models in a cache file; the other CLIs take a typed name.
    fn model_choices(&self, agent_id: &str) -> Option<Vec<String>> {
        if agent_id != "codex" {
            return None;
        }
        let cache = std::fs::read_to_string(self.codex_home.as_ref()?.join("models_cache.json")).ok()?;
        let models = codex_session_log::visible_models(&cache);
        (!models.is_empty()).then_some(models)
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
