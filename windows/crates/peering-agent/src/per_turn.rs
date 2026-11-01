//! A CLI that runs one process per turn and resumes its thread by id (Codex, OpenCode). Mirrors the Mac host's
//! `PerTurnAdapter`: run and exec mode cannot ask, so there is no approval channel, and the sandbox is the only choice.

mod arguments;

#[cfg(test)]
mod tests;

use crate::claude_adapter::{ChildProcess, LaunchSpec, ProcessLauncher, ReadResult};
use crate::codex_session_log;
use crate::codex_stream::CodexStream;
use crate::opencode_stream::OpenCodeStream;
use peering_wire::agent::{AgentPermissionMode, AgentStreamPayload, AgentTurnSummary, AgentUsage};
use std::collections::VecDeque;
use std::path::PathBuf;

/// Safest first: the folder, or everywhere.
pub const PERMISSION_MODES: [AgentPermissionMode; 2] = [AgentPermissionMode::AcceptEdits, AgentPermissionMode::Auto];
const UNKNOWN_EXIT_STATUS: i32 = -1;

pub enum TurnCli {
    Codex {
        stream: CodexStream,
        /// `<codex home>/sessions`, where the thread's log is looked for.
        sessions: Option<PathBuf>,
        log_path: codex_session_log::LogLookup,
    },
    OpenCode(OpenCodeStream),
}

impl TurnCli {
    fn feed_line(&mut self, line: &str) -> Vec<AgentStreamPayload> {
        match self {
            Self::Codex { stream, .. } => stream.feed_line(line),
            Self::OpenCode(stream) => stream.feed_line(line),
        }
    }

    fn cli_session_id(&self) -> Option<&str> {
        match self {
            Self::Codex { stream, .. } => stream.cli_session_id(),
            Self::OpenCode(stream) => stream.cli_session_id(),
        }
    }

    /// The session log knows the context and the limits and has been written once the process ends; the turn
    /// reports are the fallback when it cannot be read.
    fn usage(&mut self) -> AgentUsage {
        match self {
            Self::Codex { stream, sessions, log_path } => {
                let logged = match (sessions.as_deref(), stream.cli_session_id()) {
                    (Some(sessions), Some(thread)) => codex_session_log::read_usage(sessions, thread, log_path),
                    _ => None,
                };
                logged.unwrap_or_else(|| stream.usage().clone())
            }
            Self::OpenCode(stream) => stream.usage().clone(),
        }
    }

    fn display_name(&self) -> &'static str {
        match self {
            Self::Codex { .. } => "Codex",
            Self::OpenCode(_) => "OpenCode",
        }
    }
}

pub struct PerTurnAdapter {
    directory: PathBuf,
    cli: TurnCli,
    model: Option<String>,
    permission_mode: AgentPermissionMode,
    live: bool,
    turn: Option<Box<dyn ChildProcess>>,
    pending_prompts: VecDeque<String>,
    turn_finished: bool,
    interrupted: bool,
    usage: AgentUsage,
    usage_due: bool,
}

impl PerTurnAdapter {
    pub fn new(directory: PathBuf, cli: TurnCli, model: Option<String>, mode: Option<AgentPermissionMode>) -> Self {
        Self {
            directory,
            cli,
            model,
            permission_mode: mode.filter(|mode| PERMISSION_MODES.contains(mode)).unwrap_or(PERMISSION_MODES[0]),
            live: false,
            turn: None,
            pending_prompts: VecDeque::new(),
            turn_finished: false,
            interrupted: false,
            usage: AgentUsage::default(),
            usage_due: false,
        }
    }

    /// Nothing runs until the first prompt; a turn is a process.
    pub fn start(&mut self) {
        self.live = true;
    }

    pub fn is_running(&self) -> bool {
        self.live
    }

    pub fn cli_session_id(&self) -> Option<&str> {
        self.cli.cli_session_id()
    }

    pub fn model(&self) -> Option<&str> {
        self.model.as_deref()
    }

    pub fn permission_mode(&self) -> AgentPermissionMode {
        self.permission_mode
    }

    pub fn usage(&self) -> &AgentUsage {
        &self.usage
    }

    /// True once after a turn's process has ended, when the usage was read again.
    pub fn take_usage_due(&mut self) -> bool {
        std::mem::take(&mut self.usage_due)
    }

    /// A prompt sent while a turn runs waits for it to end.
    pub fn prompt<L: ProcessLauncher>(&mut self, text: &str, launcher: &mut L) -> bool {
        if self.turn.is_some() {
            self.pending_prompts.push_back(text.to_owned());
        } else {
            self.spawn_turn(text, launcher);
        }
        true
    }

    /// Applies from the next turn; the running one is unchanged.
    pub fn set_model(&mut self, model: Option<&str>) -> bool {
        self.model = model.map(str::to_owned);
        true
    }

    pub fn set_permission_mode(&mut self, mode: AgentPermissionMode) -> bool {
        if !PERMISSION_MODES.contains(&mode) {
            return false;
        }
        self.permission_mode = mode;
        true
    }

    pub fn interrupt(&mut self) -> bool {
        let Some(turn) = self.turn.as_mut() else {
            return false;
        };
        self.interrupted = true;
        turn.kill();
        true
    }

    pub fn stop(&mut self) {
        self.live = false;
        self.pending_prompts.clear();
        if let Some(turn) = self.turn.as_mut() {
            turn.kill();
        }
    }

    pub fn poll<L: ProcessLauncher>(&mut self, launcher: &mut L) -> Vec<AgentStreamPayload> {
        let mut payloads = Vec::new();
        while let Some(read) = self.turn.as_mut().map(|turn| turn.read_line()) {
            match read {
                ReadResult::Line(line) => payloads.extend(self.consume(&line)),
                ReadResult::Pending => break,
                ReadResult::Closed => {
                    payloads.extend(self.turn_ended());
                    if let Some(next) = self.pending_prompts.pop_front().filter(|_| self.live) {
                        self.spawn_turn(&next, launcher);
                    }
                    break;
                }
            }
        }
        payloads
    }

    fn spawn_turn<L: ProcessLauncher>(&mut self, text: &str, launcher: &mut L) {
        self.turn_finished = false;
        self.interrupted = false;
        let spec = LaunchSpec {
            program: arguments::program(&self.cli).to_owned(),
            arguments: arguments::turn_arguments(&self.cli, self.model.as_deref(), self.permission_mode, &self.directory),
            directory: self.directory.clone(),
            input: Some(text.to_owned()),
        };
        self.turn = Some(launcher.spawn(spec));
    }

    fn consume(&mut self, line: &str) -> Vec<AgentStreamPayload> {
        let payloads = self.cli.feed_line(line);
        if payloads.iter().any(|payload| matches!(payload, AgentStreamPayload::TurnFinished { .. })) {
            self.turn_finished = true;
        }
        payloads
    }

    fn turn_ended(&mut self) -> Vec<AgentStreamPayload> {
        let Some(mut turn) = self.turn.take() else {
            return Vec::new();
        };
        let status = turn.exit_status().unwrap_or(UNKNOWN_EXIT_STATUS);
        self.usage = self.cli.usage();
        self.usage_due = true;
        if self.turn_finished {
            return Vec::new();
        }
        let mut summary = unfinished_summary();
        if self.interrupted {
            summary.stopped = true;
            return vec![AgentStreamPayload::TurnFinished { summary }];
        }
        let name = self.cli.display_name();
        vec![
            AgentStreamPayload::Notice {
                text: format!("{name} exited with status {status} before finishing the turn."),
            },
            AgentStreamPayload::TurnFinished { summary },
        ]
    }
}

fn unfinished_summary() -> AgentTurnSummary {
    AgentTurnSummary {
        ok: false,
        stopped: false,
        cost_usd: None,
        input_tokens: None,
        output_tokens: None,
        duration: None,
        model: None,
    }
}
