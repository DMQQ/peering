//! Terminal names: "Terminal N" until the person names one or a command retitles it.

use peering_wire::terminal::TerminalEvent;

use super::{Outcome, TerminalSessionManager};
use crate::terminal::session::Session;

const MAXIMUM_NAME_CHARACTERS: usize = 40;

impl TerminalSessionManager {
    /// `manual` is the person's own name, which wins over the command a shell reports and is cleared by an empty one.
    pub(super) fn rename(&mut self, client_id: &str, session_id: &str, requested: &str, manual: bool) -> Outcome {
        let name = sanitized(requested);
        let resolved = {
            let Some(session) = self.sessions.get_mut(session_id).filter(|session| session.owner == client_id) else {
                return Outcome::Events(Vec::new());
            };
            if manual {
                session.manual_name = (!name.is_empty()).then_some(name);
            } else if name.is_empty() {
                return Outcome::Events(Vec::new());
            } else {
                session.last_command = Some(name);
            }
            session.manual_name.clone().or_else(|| session.last_command.clone())
        };
        let resolved = resolved.unwrap_or_else(|| self.unused_name(Some(session_id)));
        let Some(session) = self.sessions.get_mut(session_id).filter(|session| session.name != resolved) else {
            return Outcome::Events(Vec::new());
        };
        session.name = resolved;
        Outcome::Events(vec![TerminalEvent::Renamed { terminal: session.info() }])
    }

    /// The lowest "Terminal N" that no other terminal is using.
    pub(super) fn unused_name(&self, excluding: Option<&str>) -> String {
        let taken: Vec<&str> = self
            .sessions
            .values()
            .filter(|session: &&Session| Some(session.id.as_str()) != excluding)
            .map(|session| session.name.as_str())
            .collect();
        (1..).map(|number| format!("Terminal {number}")).find(|name| !taken.contains(&name.as_str())).unwrap_or_default()
    }
}

fn sanitized(requested: &str) -> String {
    let printable: String = requested.chars().filter(|character| !character.is_control()).take(MAXIMUM_NAME_CHARACTERS).collect();
    printable.trim().to_owned()
}
