//! One shell and what the manager remembers about it.

use peering_wire::terminal::TerminalSessionInfo;

use super::attention::AttentionDetector;
use super::finish::FinishDetector;
use super::pty::Pty;

/// The history kept for a client that reconnects, and how far past it the buffer grows before it is cut back.
pub(super) const MAXIMUM_HISTORY_BYTES: usize = 512 * 1024;
const HISTORY_SLACK_BYTES: usize = 64 * 1024;

pub(super) struct Session {
    pub(super) id: String,
    pub(super) owner: String,
    pub(super) created_at: f64,
    pub(super) name: String,
    pub(super) manual_name: Option<String>,
    pub(super) last_command: Option<String>,
    pub(super) pty: Box<dyn Pty>,
    pub(super) running: bool,
    pub(super) history: Vec<u8>,
    /// The grid the history was drawn for, which a client that replays it has to lay out the same way.
    pub(super) columns: u16,
    pub(super) rows: u16,
    pub(super) attention: AttentionDetector,
    pub(super) finish: FinishDetector,
}

impl Session {
    pub(super) fn info(&self) -> TerminalSessionInfo {
        TerminalSessionInfo {
            id: self.id.clone(),
            name: self.name.clone(),
            is_running: self.running,
            columns: Some(i64::from(self.columns)),
            rows: Some(i64::from(self.rows)),
            created_at: Some(self.created_at),
        }
    }

    pub(super) fn record(&mut self, data: &[u8]) {
        self.history.extend_from_slice(data);
        if self.history.len() > MAXIMUM_HISTORY_BYTES + HISTORY_SLACK_BYTES {
            let excess = self.history.len() - MAXIMUM_HISTORY_BYTES;
            self.history.drain(..excess);
        }
    }
}
