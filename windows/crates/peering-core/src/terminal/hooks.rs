//! Claude Code hooks: the lines Claude Code sends, the settings entries that make it send them, and the broker that
//! turns a permission request into a push and holds the hook until the phone answers.
//! Mirrors `MacCastKit/ClaudeHook*.swift`.

pub mod broker;
pub mod event;
pub mod reply;
pub mod settings;
