//! The command line for one turn of Codex or OpenCode. Unlike the Mac host, the prompt is sent on stdin: on Windows an
//! npm shim may run through cmd.exe, which would parse it.

use super::TurnCli;
use peering_wire::agent::AgentPermissionMode;
use std::path::Path;

pub fn program(cli: &TurnCli) -> &'static str {
    match cli {
        TurnCli::Codex { .. } => crate::codex_stream::AGENT_ID,
        TurnCli::OpenCode(_) => crate::opencode_stream::AGENT_ID,
    }
}

pub fn turn_arguments(
    cli: &TurnCli,
    model: Option<&str>,
    mode: AgentPermissionMode,
    directory: &Path,
) -> Vec<String> {
    let thread = cli.cli_session_id();
    match cli {
        TurnCli::Codex { .. } => codex(thread, model, mode, directory),
        TurnCli::OpenCode(_) => opencode(thread, model, mode),
    }
}

/// A resume names the thread only: Codex refuses to take the sandbox or folder again there, finds the thread from the
/// working directory, and takes the sandbox through `-c` instead. A prompt of `-` is read from stdin, and `--` keeps
/// a thread id from reading as a flag.
fn codex(thread: Option<&str>, model: Option<&str>, mode: AgentPermissionMode, directory: &Path) -> Vec<String> {
    let mut arguments = Vec::new();
    if let Some(model) = model {
        arguments.extend(["-c".to_owned(), format!("model={model}")]);
    }
    let sandbox = if mode == AgentPermissionMode::Auto { "danger-full-access" } else { "workspace-write" };
    if thread.is_some() {
        arguments.extend(["-c".to_owned(), format!("sandbox_mode={sandbox}")]);
    }
    arguments.push("exec".to_owned());
    match thread {
        Some(thread) => arguments.extend(
            ["resume", "--skip-git-repo-check", "--json", "--", thread, "-"].map(str::to_owned),
        ),
        None => {
            let folder = directory.to_string_lossy().into_owned();
            arguments.extend(
                ["--json", "--sandbox", sandbox, "--skip-git-repo-check", "--cd", &folder, "--", "-"].map(str::to_owned),
            );
        }
    }
    arguments
}

/// Without `--auto` a call needing approval is rejected as a failed tool, the safe direction. With no message
/// argument, `run` takes the message from piped stdin.
fn opencode(session: Option<&str>, model: Option<&str>, mode: AgentPermissionMode) -> Vec<String> {
    let mut arguments: Vec<String> = ["run", "--format", "json"].map(str::to_owned).to_vec();
    if mode == AgentPermissionMode::Auto {
        arguments.push("--auto".to_owned());
    }
    if let Some(model) = model {
        arguments.extend(["-m".to_owned(), model.to_owned()]);
    }
    if let Some(session) = session {
        arguments.extend(["-s".to_owned(), session.to_owned()]);
    }
    arguments
}
