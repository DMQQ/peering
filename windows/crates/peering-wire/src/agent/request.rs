//! Requests a client sends for an agent chat session.

use super::session::AgentPermissionMode;
use super::tool::AgentApprovalDecision;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum AgentRequest {
    List {},
    History {
        #[serde(rename = "sessionID")]
        session_id: String,
        since: u64,
    },
    Start {
        #[serde(rename = "agentID")]
        agent_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        directory: Option<String>,
    },
    Prompt {
        #[serde(rename = "sessionID")]
        session_id: String,
        text: String,
    },
    Approval {
        #[serde(rename = "sessionID")]
        session_id: String,
        #[serde(rename = "approvalID")]
        approval_id: String,
        decision: AgentApprovalDecision,
    },
    Interrupt {
        #[serde(rename = "sessionID")]
        session_id: String,
    },
    SetModel {
        #[serde(rename = "sessionID")]
        session_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        model: Option<String>,
    },
    SetPermissionMode {
        #[serde(rename = "sessionID")]
        session_id: String,
        mode: AgentPermissionMode,
    },
    Close {
        #[serde(rename = "sessionID")]
        session_id: String,
    },
    Browse {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        path: Option<String>,
    },
    Changes {
        #[serde(rename = "sessionID")]
        session_id: String,
    },
    Commit {
        #[serde(rename = "sessionID")]
        session_id: String,
        paths: Vec<String>,
        message: String,
    },
    Push {
        #[serde(rename = "sessionID")]
        session_id: String,
    },
    ListResumable {},
    Resume {
        #[serde(rename = "agentID")]
        agent_id: String,
        #[serde(rename = "cliSessionID")]
        cli_session_id: String,
    },
    Pause {
        #[serde(rename = "sessionID")]
        session_id: String,
    },
}
