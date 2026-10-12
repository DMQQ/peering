//! Drives one Claude Code process: writes prompts and answers to it, and turns what it prints into stream payloads.
//! It never spawns anything itself; the launcher it is given does.

mod approvals;
mod arguments;
mod control;
mod launch;

#[cfg(any(test, feature = "testing"))]
pub mod fake;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_control;

pub use arguments::{cli_mode_name, PERMISSION_MODES, PROGRAM};
pub use launch::{ChildProcess, LaunchSpec, ProcessLauncher, ReadResult};

use crate::claude_stream::ClaudeStream;
use arguments::launch_arguments;
use peering_wire::agent::{AgentPermissionMode, AgentStreamPayload, AgentUsage};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

const UNKNOWN_EXIT_STATUS: i32 = -1;
const EXIT_BEFORE_READY: &str = "Claude Code started and stopped before saying anything. Update it, or use the terminal instead.";

/// What a session carries into a new process so the CLI picks up its own conversation.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ClaudeResume {
    pub cli_session_id: Option<String>,
    pub model: Option<String>,
    pub permission_mode: Option<AgentPermissionMode>,
}

/// A control request this side sent and is waiting on the answer to.
#[derive(Debug, Clone, PartialEq, Eq)]
enum PendingRequest {
    SetModel { requested: Option<String> },
    SetMode(AgentPermissionMode),
}

pub struct ClaudeAdapter {
    directory: PathBuf,
    resume: ClaudeResume,
    child: Option<Box<dyn ChildProcess>>,
    stream: ClaudeStream,
    model: Option<String>,
    permission_mode: AgentPermissionMode,
    mode_before_plan: AgentPermissionMode,
    seen_ready: bool,
    next_request: u64,
    pending: HashMap<String, PendingRequest>,
    plan_approvals: HashSet<String>,
}

impl ClaudeAdapter {
    pub fn new(directory: PathBuf, resume: ClaudeResume) -> Self {
        Self {
            directory,
            model: resume.model.clone(),
            permission_mode: resume.permission_mode.unwrap_or(AgentPermissionMode::Manual),
            resume,
            child: None,
            stream: ClaudeStream::new(),
            mode_before_plan: AgentPermissionMode::Manual,
            seen_ready: false,
            next_request: 0,
            pending: HashMap::new(),
            plan_approvals: HashSet::new(),
        }
    }

    /// Starts the CLI through `launcher`. A process already running is killed first.
    pub fn start<L: ProcessLauncher>(&mut self, launcher: &mut L) {
        if let Some(mut previous) = self.child.take() {
            previous.kill();
        }
        let command = LaunchSpec {
            program: PROGRAM.to_owned(),
            arguments: launch_arguments(&self.resume),
            directory: self.directory.clone(),
        };
        self.child = Some(launcher.spawn(command));
    }

    pub fn is_running(&self) -> bool {
        self.child.is_some()
    }

    /// The CLI's own session id, which a restart resumes.
    pub fn cli_session_id(&self) -> Option<&str> {
        self.stream.cli_session_id().or(self.resume.cli_session_id.as_deref())
    }

    /// The model as the CLI resolved it. Set by the CLI's init and turn summaries, and by a confirmed `set_model`.
    pub fn model(&self) -> Option<&str> {
        self.model.as_deref()
    }

    pub fn permission_mode(&self) -> AgentPermissionMode {
        self.permission_mode
    }

    pub fn usage(&self) -> &AgentUsage {
        self.stream.usage()
    }

    pub fn prompt(&mut self, text: &str) -> bool {
        self.send(&json!({
            "type": "user",
            "message": {"role": "user", "content": text},
            "parent_tool_use_id": null,
        }))
    }

    pub fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            child.kill();
        }
    }

    /// Reads every line the process has printed so far and returns what they mean, in order. Reports the end of
    /// the process once, as a failure (if it ended badly) and then `SessionExited`.
    pub fn poll(&mut self) -> Vec<AgentStreamPayload> {
        let mut payloads = Vec::new();
        while let Some(read) = self.child.as_mut().map(|child| child.read_line()) {
            match read {
                ReadResult::Line(line) => payloads.extend(self.consume(&line)),
                ReadResult::Pending => break,
                ReadResult::Closed => {
                    payloads.extend(self.ended());
                    break;
                }
            }
        }
        payloads
    }

    fn consume(&mut self, line: &str) -> Vec<AgentStreamPayload> {
        if let Some(answered) = self.take_control_response(line) {
            return answered;
        }
        let payloads = self.stream.feed_line(line);
        for payload in &payloads {
            self.note(payload);
        }
        payloads
    }

    /// Bookkeeping the adapter's getters and the approval path need from each payload.
    fn note(&mut self, payload: &AgentStreamPayload) {
        match payload {
            AgentStreamPayload::SessionReady { model, .. } => {
                self.seen_ready = true;
                if model.is_some() {
                    self.model = model.clone();
                }
            }
            AgentStreamPayload::TurnFinished { summary } => {
                if summary.model.is_some() {
                    self.model = summary.model.clone();
                }
            }
            AgentStreamPayload::ApprovalRequested { approval_id, call, .. } if call.name == "ExitPlanMode" => {
                self.plan_approvals.insert(approval_id.clone());
            }
            _ => {}
        }
    }

    fn ended(&mut self) -> Vec<AgentStreamPayload> {
        let Some(mut child) = self.child.take() else {
            return Vec::new();
        };
        let status = child.exit_status().unwrap_or(UNKNOWN_EXIT_STATUS);
        let mut payloads = Vec::new();
        if !self.seen_ready {
            payloads.push(failure(EXIT_BEFORE_READY));
        } else if status != 0 {
            payloads.push(failure(&format!("Claude Code exited with status {status}.")));
        }
        payloads.push(AgentStreamPayload::SessionExited { status });
        payloads
    }

    /// False when the process has not taken the line. Callers report that; nothing is queued for later.
    fn send(&mut self, value: &Value) -> bool {
        let Some(child) = self.child.as_mut() else {
            return false;
        };
        child.write_line(&value.to_string())
    }
}

fn failure(message: &str) -> AgentStreamPayload {
    AgentStreamPayload::Failure {
        message: message.to_owned(),
    }
}
