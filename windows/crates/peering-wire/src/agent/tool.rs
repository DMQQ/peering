//! Approval verdicts, questions, plans and tool calls, in the shape both CLI adapters normalise into.

use serde::{Deserialize, Serialize};

/// The user's verdict on one approval prompt. `Choose` answers a question-style ask with one label per question.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum AgentApprovalDecision {
    Allow {},
    Deny {},
    Choose {
        #[serde(rename = "_0")]
        answers: Vec<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentToolOption {
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// One question of an `AskUserQuestion` ask, with the choices offered for it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentQuestion {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub header: Option<String>,
    pub question: String,
    pub options: Vec<AgentToolOption>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AgentPlanStepStatus {
    Pending,
    InProgress,
    Completed,
}

impl AgentPlanStepStatus {
    /// The CLIs spell the states `in_progress`, `inProgress` or `done`; anything unrecognised is still to do.
    pub fn from_raw(raw: Option<&str>) -> Self {
        let normalised = raw.map(|text| text.to_lowercase().replace('_', ""));
        match normalised.as_deref() {
            Some("inprogress" | "active" | "running") => Self::InProgress,
            Some("completed" | "complete" | "done") => Self::Completed,
            _ => Self::Pending,
        }
    }
}

/// One line of an agent's own plan, as its to-do tool last wrote it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentPlanStep {
    pub text: String,
    pub status: AgentPlanStepStatus,
}

/// One tool call. `name` is the CLI's raw tool name and stays open so a new tool draws a generic card.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentToolCall {
    pub id: String,
    pub name: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diff: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub questions: Option<Vec<AgentQuestion>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<Vec<AgentPlanStep>>,
}

/// What one finished turn cost. Each field is optional because the CLIs report different things.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentTurnSummary {
    pub ok: bool,
    #[serde(default)]
    pub stopped: bool,
    #[serde(default, rename = "costUSD", skip_serializing_if = "Option::is_none")]
    pub cost_usd: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_tokens: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_tokens: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
}
