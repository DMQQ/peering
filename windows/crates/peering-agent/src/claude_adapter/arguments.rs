//! The command line Claude Code is started with, and the names its permission modes go by.

use super::ClaudeResume;
use peering_wire::agent::AgentPermissionMode;

pub const PROGRAM: &str = "claude";

/// Safest first. Claude has no unattended mode under these names, so it is not listed.
pub const PERMISSION_MODES: [AgentPermissionMode; 4] = [
    AgentPermissionMode::Manual,
    AgentPermissionMode::AcceptEdits,
    AgentPermissionMode::Plan,
    AgentPermissionMode::Auto,
];

const BASE_ARGUMENTS: [&str; 10] = [
    "-p",
    "--input-format",
    "stream-json",
    "--output-format",
    "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--replay-user-messages",
    "--permission-prompt-tool",
    "stdio",
];

/// `--permission-prompt-tool stdio` sends permission prompts to us as `can_use_tool` requests. Without it the CLI
/// denies tools that need approval itself, and nothing reaches the phone.
pub fn launch_arguments(resume: &ClaudeResume) -> Vec<String> {
    let mut arguments: Vec<String> = BASE_ARGUMENTS.iter().map(|flag| (*flag).to_owned()).collect();
    if let Some(id) = &resume.cli_session_id {
        arguments.extend(["--resume".to_owned(), id.clone()]);
    }
    if let Some(model) = &resume.model {
        arguments.extend(["--model".to_owned(), model.clone()]);
    }
    if let Some(mode) = resume.permission_mode.filter(|mode| *mode != AgentPermissionMode::Manual) {
        arguments.extend(["--permission-mode".to_owned(), cli_mode_name(mode).to_owned()]);
    }
    arguments
}

/// The name `--permission-mode` and `set_permission_mode` take. `Auto` is Claude's classifier mode, where a reviewer
/// model checks each action.
pub fn cli_mode_name(mode: AgentPermissionMode) -> &'static str {
    match mode {
        AgentPermissionMode::AcceptEdits => "acceptEdits",
        AgentPermissionMode::Plan => "plan",
        AgentPermissionMode::Auto => "auto",
        AgentPermissionMode::Manual => "default",
    }
}
