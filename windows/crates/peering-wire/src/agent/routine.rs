//! A prompt the host sends to an agent on a schedule, in a chat of its own. Shaped as `AgentRoutine.swift`; dates are seconds
//! since 2001-01-01, as every date on this wire is.

use super::session::AgentPermissionMode;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentRoutine {
    /// An uppercase UUID string.
    pub id: String,
    pub name: String,
    #[serde(rename = "agentID")]
    pub agent_id: String,
    /// An absolute path on the host.
    pub directory: String,
    pub prompt: String,
    pub schedule: AgentRoutineSchedule,
    pub permission_mode: AgentPermissionMode,
    pub is_enabled: bool,
    /// The host stops the run once it has gone on this long. `None` lets it finish.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stop_after_minutes: Option<i64>,
    /// Whether the phone is told when a run ends, wherever the phone is. `None` means yes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notifies_when_done: Option<bool>,
    /// Kept by the host: whatever the phone sends here is ignored.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_run: Option<AgentRoutineRun>,
    /// Kept by the host, as `last_run` is.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_run_at: Option<f64>,
}

/// When a routine runs. Weekdays are numbered 1 for Sunday to 7 for Saturday.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum AgentRoutineSchedule {
    Every { minutes: i64 },
    Daily { hour: i64, minute: i64, weekdays: Vec<i64> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AgentRoutineOutcome {
    Running,
    Succeeded,
    Failed,
    /// Ended by the routine's own time limit.
    Stopped,
    /// Never started; `detail` says why.
    Skipped,
}

/// One run of a routine, as the host last recorded it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentRoutineRun {
    pub started_at: f64,
    pub outcome: AgentRoutineOutcome,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// The chat the run happened in. `None` for a run that was skipped.
    #[serde(default, rename = "sessionID", skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
}
