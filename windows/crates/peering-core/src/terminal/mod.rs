//! Terminal sessions: shells run behind a `Pty` port, owned by the client that opened them, with the output a
//! reconnecting client replays and the prompts and finished commands a phone is told about.
//! Mirrors `apple/PeeringHost/Terminal/TerminalSessionManager.swift` and its extensions.

pub mod attention;
pub mod fake;
pub mod finish;
pub mod hooks;
pub mod manager;
pub mod push;
pub mod pty;
mod session;
pub mod shell;
mod text;
