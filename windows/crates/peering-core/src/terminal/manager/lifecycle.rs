//! Starting, feeding, resizing and ending a shell.

use peering_wire::terminal::TerminalEvent;

use super::{failed, Outcome, TerminalSessionManager, GONE, MAXIMUM_INPUT_BYTES, MAXIMUM_SESSIONS_PER_CLIENT};
use crate::terminal::attention::AttentionDetector;
use crate::terminal::finish::FinishDetector;
use crate::terminal::pty::SpawnRequest;
use crate::terminal::session::Session;

const INITIAL_COLUMNS: u16 = 100;
const INITIAL_ROWS: u16 = 30;
/// Seconds from the Unix epoch to 2001-01-01, the reference date the wire counts from.
const UNIX_TO_REFERENCE_SECONDS: f64 = 978_307_200.0;

impl TerminalSessionManager {
    pub(super) fn create(&mut self, client_id: &str) -> Outcome {
        let owned = self.sessions.values().filter(|session| session.owner == client_id).count();
        if owned >= MAXIMUM_SESSIONS_PER_CLIENT {
            return failed(None, "Terminal session limit reached.");
        }
        let Some(shell) = self.config.shells.first() else {
            return failed(None, "This PC has no shell to start.");
        };
        let request = SpawnRequest {
            shell,
            directory: &self.config.directory,
            environment: &self.config.environment,
            columns: INITIAL_COLUMNS,
            rows: INITIAL_ROWS,
        };
        let id = (self.deps.new_id)();
        let pty = match self.deps.spawner.spawn(&request) {
            Ok(pty) => pty,
            Err(error) => return failed(Some(&id), &format!("Could not start the shell: {error}")),
        };
        let session = Session {
            name: self.unused_name(None),
            created_at: self.deps.clock.unix_seconds() as f64 - UNIX_TO_REFERENCE_SECONDS,
            id: id.clone(),
            owner: client_id.to_owned(),
            manual_name: None,
            last_command: None,
            pty,
            running: true,
            history: Vec::new(),
            columns: INITIAL_COLUMNS,
            rows: INITIAL_ROWS,
            attention: AttentionDetector::default(),
            finish: FinishDetector::default(),
        };
        let created = TerminalEvent::Created { terminal: session.info() };
        self.sessions.insert(id, session);
        Outcome::Events(vec![created])
    }

    pub(super) fn input(&mut self, client_id: &str, session_id: &str, data: &[u8]) -> Outcome {
        if data.len() > MAXIMUM_INPUT_BYTES {
            return failed(Some(session_id), "Terminal input was too large.");
        }
        let Some(session) = self.live_session(client_id, session_id) else {
            return failed(Some(session_id), GONE);
        };
        session.attention.user_did_respond();
        match session.pty.write(data) {
            Ok(()) => Outcome::Events(Vec::new()),
            Err(_) => failed(Some(session_id), "Could not write to the terminal."),
        }
    }

    pub(super) fn resize(&mut self, client_id: &str, session_id: &str, columns: u16, rows: u16) -> Outcome {
        let Some(session) = self.sessions.get_mut(session_id).filter(|session| session.owner == client_id) else {
            return Outcome::Events(Vec::new());
        };
        if columns == 0 || rows == 0 || session.pty.resize(columns, rows).is_err() {
            return Outcome::Events(Vec::new());
        }
        session.columns = columns;
        session.rows = rows;
        Outcome::Events(Vec::new())
    }

    pub(super) fn close(&mut self, client_id: &str, session_id: &str) -> Outcome {
        if self.sessions.get(session_id).is_none_or(|session| session.owner != client_id) {
            return Outcome::Events(Vec::new());
        }
        if let Some(mut session) = self.sessions.remove(session_id) {
            if session.running {
                session.pty.kill();
            }
        }
        Outcome::Events(vec![TerminalEvent::Closed { session_id: session_id.to_owned() }])
    }

    pub(super) fn live_session(&mut self, client_id: &str, session_id: &str) -> Option<&mut Session> {
        self.sessions.get_mut(session_id).filter(|session| session.owner == client_id && session.running)
    }
}
