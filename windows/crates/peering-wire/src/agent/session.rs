//! Session listing types: what a chat looks like before its transcript is read.

use serde::{Deserialize, Serialize};

/// How freely an agent may act without asking. A session lists the modes its CLI supports in `permission_modes`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AgentPermissionMode {
    Manual,
    AcceptEdits,
    Plan,
    Auto,
}

/// What a session has used, as far as its CLI reports it. Unreported fields stay `None`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentUsage {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_used_tokens: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_window_tokens: Option<i64>,
    #[serde(default)]
    pub input_tokens: i64,
    #[serde(default)]
    pub cached_tokens: i64,
    #[serde(default)]
    pub output_tokens: i64,
    #[serde(default, rename = "costUSD", skip_serializing_if = "Option::is_none")]
    pub cost_usd: Option<f64>,
    #[serde(default)]
    pub limits: Vec<AgentUsageLimit>,
}

/// One rate-limit window. `used_fraction` runs from 0 to 1; `resets_at` is seconds since 2001-01-01.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentUsageLimit {
    pub label: String,
    pub used_fraction: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<f64>,
}

/// A chat session as the Mac lists it. `id` is an uppercase UUID string; `created_at` is seconds since 2001-01-01.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentSessionInfo {
    pub id: String,
    #[serde(rename = "agentID")]
    pub agent_id: String,
    pub title: String,
    pub directory: String,
    pub state: AgentSessionState,
    pub last_index: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission_mode: Option<AgentPermissionMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission_modes: Option<Vec<AgentPermissionMode>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_choices: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage: Option<AgentUsage>,
    pub created_at: f64,
}

/// What a session is doing: a fact about the turn, not the process.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AgentSessionState {
    Idle,
    Working,
    AwaitingApproval,
    Exited,
    Failed,
}
