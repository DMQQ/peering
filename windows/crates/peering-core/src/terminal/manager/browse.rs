//! Who may browse files through a session id: the owner of a shell that is still running, or the client that opened
//! a browsing scope with `startBrowser`.

use peering_wire::terminal::TerminalRequest;

use super::{failed, Outcome, TerminalSessionManager, GONE, MAXIMUM_BROWSERS_PER_CLIENT};

impl TerminalSessionManager {
    pub(super) fn browse(&mut self, client_id: &str, request: &TerminalRequest) -> Outcome {
        let session_id = match request {
            TerminalRequest::StartBrowser { id } => {
                let held = self.browsers.values().filter(|owner| owner.as_str() == client_id).count();
                if held < MAXIMUM_BROWSERS_PER_CLIENT {
                    self.browsers.insert(id.clone(), client_id.to_owned());
                }
                return Outcome::Events(Vec::new());
            }
            TerminalRequest::ListDirectory { session_id, .. }
            | TerminalRequest::ReadFile { session_id, .. }
            | TerminalRequest::ReadRange { session_id, .. }
            | TerminalRequest::ArchiveFolder { session_id, .. }
            | TerminalRequest::BeginWrite { session_id, .. }
            | TerminalRequest::WriteChunk { session_id, .. }
            | TerminalRequest::ChangeFile { session_id, .. } => session_id,
            _ => return Outcome::Events(Vec::new()),
        };
        if self.can_browse(client_id, session_id) {
            Outcome::Browse
        } else {
            failed(Some(session_id), GONE)
        }
    }

    fn can_browse(&self, client_id: &str, session_id: &str) -> bool {
        self.sessions.get(session_id).is_some_and(|session| session.owner == client_id && session.running)
            || self.browsers.get(session_id).is_some_and(|owner| owner == client_id)
    }
}
