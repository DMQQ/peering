//! One event in an agent session's stream. The index is monotonic per session; see `AgentStreamEvent`.

use super::tool::{AgentApprovalDecision, AgentToolCall, AgentTurnSummary};
use serde::{Deserialize, Serialize};

/// One thing that happened in an agent session. Clients apply an event only if its index exceeds the last applied.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentStreamEvent {
    pub index: u64,
    pub payload: AgentStreamPayload,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum AgentStreamPayload {
    SessionReady {
        #[serde(rename = "agentID")]
        agent_id: String,
        #[serde(default, rename = "cliSessionID", skip_serializing_if = "Option::is_none")]
        cli_session_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        model: Option<String>,
        directory: String,
    },
    UserPrompt {
        text: String,
    },
    TurnStarted {},
    TextDelta {
        text: String,
    },
    TextFinal {
        text: String,
    },
    ToolStarted {
        call: AgentToolCall,
    },
    ToolFinished {
        #[serde(rename = "callID")]
        call_id: String,
        ok: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        output: Option<String>,
        truncated: bool,
    },
    ApprovalRequested {
        #[serde(rename = "approvalID")]
        approval_id: String,
        call: AgentToolCall,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    ApprovalResolved {
        #[serde(rename = "approvalID")]
        approval_id: String,
        decision: AgentApprovalDecision,
    },
    TurnFinished {
        summary: AgentTurnSummary,
    },
    Notice {
        text: String,
    },
    Failure {
        message: String,
    },
    SessionExited {
        status: i32,
    },
    Child {
        #[serde(rename = "parentCallID")]
        parent_call_id: String,
        event: Box<AgentStreamPayload>,
    },
}
