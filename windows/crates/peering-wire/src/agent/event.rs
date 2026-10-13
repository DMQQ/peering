//! Events the Mac sends an agent chat client.
//!
//! `directory` entries, the `changes` report, the `gitResult` and the `resumable` listing stay as raw JSON here:
//! their models belong to the file browser and git features, and a decode of this enum must not fail on them.

use super::session::{AgentPermissionMode, AgentSessionInfo, AgentUsage};
use super::stream::AgentStreamEvent;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum AgentEvent {
    Snapshot {
        #[serde(rename = "_0")]
        sessions: Vec<AgentSessionInfo>,
    },
    Created {
        #[serde(rename = "_0")]
        session: AgentSessionInfo,
    },
    Stream {
        #[serde(rename = "sessionID")]
        session_id: String,
        event: AgentStreamEvent,
    },
    Replay {
        #[serde(rename = "sessionID")]
        session_id: String,
        events: Vec<AgentStreamEvent>,
        is_last: bool,
        truncated_at_front: bool,
    },
    Directory {
        path: String,
        entries: Vec<Value>,
        truncated: bool,
    },
    BrowseFailure {
        path: String,
        message: String,
    },
    BrowseWaiting {
        path: String,
        message: String,
    },
    Changes {
        #[serde(rename = "sessionID")]
        session_id: String,
        report: Value,
    },
    GitResult {
        #[serde(rename = "sessionID")]
        session_id: String,
        result: Value,
    },
    Closed {
        #[serde(rename = "sessionID")]
        session_id: String,
    },
    ModelChanged {
        #[serde(rename = "sessionID")]
        session_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        model: Option<String>,
    },
    PermissionModeChanged {
        #[serde(rename = "sessionID")]
        session_id: String,
        mode: AgentPermissionMode,
    },
    UsageChanged {
        #[serde(rename = "sessionID")]
        session_id: String,
        usage: AgentUsage,
    },
    Failed {
        #[serde(rename = "sessionID", default, skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
        message: String,
    },
    Resumable {
        #[serde(rename = "_0")]
        sessions: Vec<Value>,
    },
}
