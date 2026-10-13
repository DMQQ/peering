//! Terminal sessions for the clients of one host. A session belongs to the client that opened it, outlives that client's
//! connection, and replays its history to the next one. Pure over the `Pty` port, so it runs against a fake shell in tests.

mod browse;
mod lifecycle;
mod naming;
mod output;

#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_output;

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use peering_wire::terminal::{TerminalEvent, TerminalRequest};

use super::push::{AgentLocator, PushAlert, PushTokens};
use super::pty::PtySpawner;
use super::session::Session;
use super::shell::Shell;
use crate::ports::clock::Clock;

pub use output::{Outbound, Poll};

pub const MAXIMUM_SESSIONS_PER_CLIENT: usize = 10;
pub const MAXIMUM_BROWSERS_PER_CLIENT: usize = 4;
pub const MAXIMUM_INPUT_BYTES: usize = 64 * 1024;
const KNOWN_AGENTS: [&str; 6] = ["claude", "codex", "opencode", "hermes", "gemini", "aider"];
const GONE: &str = "That terminal is no longer running.";

pub struct TerminalDeps {
    pub spawner: Box<dyn PtySpawner>,
    pub tokens: Box<dyn PushTokens>,
    pub agents: Box<dyn AgentLocator>,
    pub clock: Arc<dyn Clock>,
    /// An uppercase UUID string, unique among sessions.
    pub new_id: Box<dyn FnMut() -> String>,
}

pub struct TerminalConfig {
    /// In the order they are offered; the first starts new terminals.
    pub shells: Vec<Shell>,
    /// Where a new terminal starts.
    pub directory: String,
    pub environment: Vec<(String, String)>,
}

/// What a request needs the caller to do.
#[derive(Debug, PartialEq)]
pub enum Outcome {
    /// Events to send to the client that asked, in order.
    Events(Vec<TerminalEvent>),
    /// A file request this client may make: the file service answers it.
    Browse,
}

pub struct TerminalSessionManager {
    deps: TerminalDeps,
    config: TerminalConfig,
    sessions: BTreeMap<String, Session>,
    attached: BTreeSet<String>,
    /// File-browsing scopes that are not shells, by the id the phone made for each.
    browsers: BTreeMap<String, String>,
}

impl TerminalSessionManager {
    pub fn new(deps: TerminalDeps, config: TerminalConfig) -> Self {
        Self { deps, config, sessions: BTreeMap::new(), attached: BTreeSet::new(), browsers: BTreeMap::new() }
    }

    pub fn handle(&mut self, client_id: &str, request: &TerminalRequest) -> Outcome {
        if client_id.is_empty() {
            return failed(None, "The authenticated device has no identity.");
        }
        self.attached.insert(client_id.to_owned());
        match request {
            TerminalRequest::Agents {} => Outcome::Events(vec![TerminalEvent::Agents {
                installed: self.deps.agents.installed(&KNOWN_AGENTS),
            }]),
            TerminalRequest::List {} => Outcome::Events(self.snapshot(client_id)),
            TerminalRequest::Create {} => self.create(client_id),
            TerminalRequest::Input { session_id, data } => self.input(client_id, session_id, data),
            TerminalRequest::Resize { session_id, columns, rows } => self.resize(client_id, session_id, *columns, *rows),
            TerminalRequest::Rename { session_id, name } => self.rename(client_id, session_id, name, true),
            TerminalRequest::Retitle { session_id, command } => self.rename(client_id, session_id, command, false),
            TerminalRequest::Close { session_id } => self.close(client_id, session_id),
            TerminalRequest::RegisterPushToken { token } => self.register_push_token(client_id, token),
            other => self.browse(client_id, other),
        }
    }

    /// The push token of every phone that registered one.
    pub fn push_tokens(&self) -> Vec<String> {
        self.deps.tokens.all_tokens()
    }

    /// The push token this phone registered, if it did.
    pub fn push_token_for(&self, client_id: &str) -> Option<String> {
        self.deps.tokens.token_for(client_id)
    }

    /// Forgets that the client is listening. Its shells keep running and keep their history.
    pub fn disconnect(&mut self, client_id: &str) {
        self.attached.remove(client_id);
        self.browsers.retain(|_, owner| owner != client_id);
    }

    fn register_push_token(&mut self, client_id: &str, token: &[u8]) -> Outcome {
        if self.deps.tokens.register(client_id, token) {
            return Outcome::Events(Vec::new());
        }
        failed(None, "The notification token could not be saved.")
    }

    fn snapshot(&self, client_id: &str) -> Vec<TerminalEvent> {
        let mut mine: Vec<&Session> = self.sessions.values().filter(|session| session.owner == client_id).collect();
        mine.sort_by(|left, right| left.name.cmp(&right.name));
        let mut events = vec![TerminalEvent::Snapshot { terminals: mine.iter().map(|session| session.info()).collect() }];
        for session in mine {
            events.extend(output::output_events(&session.id, &session.history));
        }
        events
    }
}

impl Drop for TerminalSessionManager {
    fn drop(&mut self) {
        for session in self.sessions.values_mut().filter(|session| session.running) {
            session.pty.kill();
        }
    }
}

fn failed(session_id: Option<&str>, message: &str) -> Outcome {
    Outcome::Events(vec![TerminalEvent::Failed { session_id: session_id.map(str::to_owned), message: message.to_owned() }])
}
