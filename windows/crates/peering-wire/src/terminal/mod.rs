//! Terminal and file-browser wire models, shaped as the Swift `Codable` output in `TerminalWire.swift`.
//! See docs/protocol.md section 7.

mod event;
mod request;
mod session;

#[cfg(test)]
mod tests;

pub use event::{TerminalAttentionKind, TerminalEvent};
pub use request::TerminalRequest;
pub use session::TerminalSessionInfo;
