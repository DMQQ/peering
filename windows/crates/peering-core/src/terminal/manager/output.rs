//! Reading what the shells print, and telling the owner: output in events of at most 64 KiB, then any prompt or
//! finished command found in it. A client that is not connected is told by push instead of by event.

use peering_wire::terminal::{TerminalAttentionKind, TerminalEvent};

use super::{PushAlert, TerminalSessionManager};
use crate::terminal::finish::{duration_suffix, Finish};
use crate::terminal::session::Session;

pub const MAXIMUM_OUTPUT_EVENT_BYTES: usize = 64 * 1024;
/// What one session may deliver per poll, so a shell that never stops printing cannot starve the others.
const READ_BUDGET_BYTES: usize = 1024 * 1024;

#[derive(Debug, PartialEq)]
pub struct Outbound {
    pub client_id: String,
    pub event: TerminalEvent,
}

#[derive(Debug, Default, PartialEq)]
pub struct Poll {
    pub events: Vec<Outbound>,
    pub pushes: Vec<PushAlert>,
}

enum Notice {
    Attention { kind: TerminalAttentionKind, message: String },
    Finished { finish: Finish, message: String },
}

impl TerminalSessionManager {
    /// Reads every running shell without waiting. The caller calls this often and sends what it returns.
    pub fn poll(&mut self) -> Poll {
        let mut poll = Poll::default();
        for session in self.sessions.values_mut() {
            if !session.running {
                continue;
            }
            let (output, notices) = read_session(session);
            let listening = self.attached.contains(&session.owner);
            let mut events = output_events(&session.id, &output);
            for notice in notices {
                if listening {
                    events.push(notice.event(&session.id));
                } else if let Some(token) = self.deps.tokens.token_for(&session.owner) {
                    poll.pushes.push(notice.alert(token));
                }
            }
            if let Some(status) = session.pty.exit_status() {
                session.running = false;
                events.push(TerminalEvent::Exited { session_id: session.id.clone(), status });
            }
            if listening {
                let client_id = &session.owner;
                poll.events.extend(events.into_iter().map(|event| Outbound { client_id: client_id.clone(), event }));
            }
        }
        poll
    }
}

fn read_session(session: &mut Session) -> (Vec<u8>, Vec<Notice>) {
    let mut output = Vec::new();
    let mut notices = Vec::new();
    while output.len() < READ_BUDGET_BYTES {
        let crate::terminal::pty::PtyRead::Data(data) = session.pty.read() else {
            break;
        };
        session.record(&data);
        if let Some(kind) = session.attention.receive(&data) {
            notices.push(attention_notice(session, kind));
        }
        if let Some(finish) = session.finish.receive(&data) {
            notices.push(finished_notice(session, finish));
        }
        output.extend_from_slice(&data);
    }
    (output, notices)
}

fn attention_notice(session: &Session, kind: TerminalAttentionKind) -> Notice {
    let noun = if kind == TerminalAttentionKind::Password { "a password" } else { "confirmation" };
    let fallback = format!("Terminal \u{201C}{}\u{201D} is waiting for {noun}.", session.name);
    Notice::Attention { kind, message: session.attention.question().unwrap_or(fallback) }
}

fn finished_notice(session: &Session, finish: Finish) -> Notice {
    let named = match &finish.command {
        Some(command) => format!("\u{201C}{command}\u{201D}"),
        None => format!("Terminal \u{201C}{}\u{201D}", session.name),
    };
    let message = format!("{named} finished{}.", duration_suffix(finish.duration));
    Notice::Finished { finish, message }
}

impl Notice {
    fn event(self, session_id: &str) -> TerminalEvent {
        let session_id = session_id.to_owned();
        match self {
            Self::Attention { kind, message } => TerminalEvent::Attention { session_id, kind, message },
            Self::Finished { finish, .. } => TerminalEvent::CommandFinished {
                session_id,
                command: finish.command,
                duration: finish.duration,
                exit_status: finish.exit_status,
            },
        }
    }

    fn alert(self, token: String) -> PushAlert {
        match self {
            Self::Attention { message, .. } => PushAlert { token, title: "Terminal needs you".to_owned(), message },
            Self::Finished { message, .. } => PushAlert { token, title: "Terminal finished".to_owned(), message },
        }
    }
}

pub(super) fn output_events(session_id: &str, bytes: &[u8]) -> Vec<TerminalEvent> {
    bytes
        .chunks(MAXIMUM_OUTPUT_EVENT_BYTES)
        .map(|chunk| TerminalEvent::Output { session_id: session_id.to_owned(), data: chunk.to_vec() })
        .collect()
}
