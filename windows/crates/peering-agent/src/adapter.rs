//! The agents a chat can run, and one adapter type over them so the manager does not care which CLI a chat runs.

use crate::claude_adapter::{self, ClaudeAdapter, ClaudeResume, ProcessLauncher};
use crate::codex_stream::CodexStream;
use crate::opencode_stream::OpenCodeStream;
use crate::per_turn::{self, PerTurnAdapter, TurnCli};
use peering_wire::agent::{AgentApprovalDecision, AgentPermissionMode, AgentStreamPayload, AgentUsage};
use std::path::{Path, PathBuf};

/// Every agent this host knows, by id (which is also the command it runs) and the name a title starts with.
pub const AGENTS: [(&str, &str); 3] = [("claude", "Claude Code"), ("codex", "Codex"), ("opencode", "OpenCode")];

pub fn agent_name(agent_id: &str) -> Option<&'static str> {
    AGENTS.iter().find(|(id, _)| *id == agent_id).map(|(_, name)| *name)
}

/// What a chat carries into a new process so the CLI picks up its own conversation.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AgentResume {
    pub cli_session_id: Option<String>,
    pub model: Option<String>,
    pub permission_mode: Option<AgentPermissionMode>,
}

pub enum AgentAdapter {
    Claude(ClaudeAdapter),
    PerTurn(PerTurnAdapter),
}

impl AgentAdapter {
    /// `None` for an agent id this host does not know. `codex_sessions` is where Codex keeps its thread logs.
    pub fn make(agent_id: &str, directory: &Path, resume: AgentResume, codex_sessions: Option<&Path>) -> Option<Self> {
        let folder = directory.to_string_lossy();
        let AgentResume { cli_session_id, model, permission_mode } = resume;
        let cli = match agent_id {
            "claude" => {
                let resume = ClaudeResume { cli_session_id, model, permission_mode };
                return Some(Self::Claude(ClaudeAdapter::new(directory.to_path_buf(), resume)));
            }
            "codex" => TurnCli::Codex {
                stream: CodexStream::new(&folder, cli_session_id),
                sessions: codex_sessions.map(Path::to_path_buf),
                log_path: crate::codex_session_log::LogLookup::default(),
            },
            "opencode" => TurnCli::OpenCode(OpenCodeStream::new(&folder, cli_session_id)),
            _ => return None,
        };
        Some(Self::PerTurn(PerTurnAdapter::new(PathBuf::from(directory), cli, model, permission_mode)))
    }

    pub fn start<L: ProcessLauncher>(&mut self, launcher: &mut L) {
        match self {
            Self::Claude(adapter) => adapter.start(launcher),
            Self::PerTurn(adapter) => adapter.start(),
        }
    }

    pub fn is_running(&self) -> bool {
        match self {
            Self::Claude(adapter) => adapter.is_running(),
            Self::PerTurn(adapter) => adapter.is_running(),
        }
    }

    pub fn cli_session_id(&self) -> Option<&str> {
        match self {
            Self::Claude(adapter) => adapter.cli_session_id(),
            Self::PerTurn(adapter) => adapter.cli_session_id(),
        }
    }

    pub fn model(&self) -> Option<&str> {
        match self {
            Self::Claude(adapter) => adapter.model(),
            Self::PerTurn(adapter) => adapter.model(),
        }
    }

    pub fn permission_mode(&self) -> AgentPermissionMode {
        match self {
            Self::Claude(adapter) => adapter.permission_mode(),
            Self::PerTurn(adapter) => adapter.permission_mode(),
        }
    }

    pub fn permission_modes(&self) -> &'static [AgentPermissionMode] {
        match self {
            Self::Claude(_) => &claude_adapter::PERMISSION_MODES,
            Self::PerTurn(_) => &per_turn::PERMISSION_MODES,
        }
    }

    pub fn usage(&self) -> &AgentUsage {
        match self {
            Self::Claude(adapter) => adapter.usage(),
            Self::PerTurn(adapter) => adapter.usage(),
        }
    }

    /// True when the usage was read again outside a turn's end, which a per-turn CLI does once its process exits.
    pub fn take_usage_due(&mut self) -> bool {
        match self {
            Self::Claude(_) => false,
            Self::PerTurn(adapter) => adapter.take_usage_due(),
        }
    }

    pub fn prompt<L: ProcessLauncher>(&mut self, text: &str, launcher: &mut L) -> bool {
        match self {
            Self::Claude(adapter) => adapter.prompt(text),
            Self::PerTurn(adapter) => adapter.prompt(text, launcher),
        }
    }

    /// The per-turn CLIs have no approval channel, so there is nothing to answer.
    pub fn respond(&mut self, approval_id: &str, decision: &AgentApprovalDecision) -> bool {
        match self {
            Self::Claude(adapter) => adapter.respond(approval_id, decision),
            Self::PerTurn(_) => true,
        }
    }

    pub fn interrupt(&mut self) -> bool {
        match self {
            Self::Claude(adapter) => adapter.interrupt(),
            Self::PerTurn(adapter) => adapter.interrupt(),
        }
    }

    pub fn set_model(&mut self, model: Option<&str>) -> bool {
        match self {
            Self::Claude(adapter) => adapter.set_model(model),
            Self::PerTurn(adapter) => adapter.set_model(model),
        }
    }

    pub fn set_permission_mode(&mut self, mode: AgentPermissionMode) -> bool {
        match self {
            Self::Claude(adapter) => adapter.set_permission_mode(mode),
            Self::PerTurn(adapter) => adapter.set_permission_mode(mode),
        }
    }

    pub fn stop(&mut self) {
        match self {
            Self::Claude(adapter) => adapter.stop(),
            Self::PerTurn(adapter) => adapter.stop(),
        }
    }

    pub fn poll<L: ProcessLauncher>(&mut self, launcher: &mut L) -> Vec<AgentStreamPayload> {
        match self {
            Self::Claude(adapter) => adapter.poll(),
            Self::PerTurn(adapter) => adapter.poll(launcher),
        }
    }
}
