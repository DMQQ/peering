//! Agent chat sessions: spawning coding agent CLIs and turning their output into wire events. No Windows API in the logic.

pub mod adapter;
pub mod availability;
pub mod browse;
pub mod claude_adapter;
pub mod claude_stream;
pub mod codex_session_log;
pub mod codex_stream;
pub mod environment;
pub mod git;
pub mod manager;
pub mod opencode_stream;
pub mod per_turn;
pub mod process_tree;
pub mod push;
pub mod routines;
