//! Agent chat sessions: spawning coding agent CLIs and turning their output into wire events. No Windows API in the logic.

pub mod availability;
pub mod browse;
pub mod claude_adapter;
pub mod claude_stream;
pub mod environment;
pub mod manager;
pub mod push;
