//! One Codex item, started or completed, as tool cards, replies and notices.

use super::{notice, CodexStream};
use crate::claude_stream::json::{object_array, str_field, Object};
use crate::claude_stream::text::{trimmed, MAXIMUM_TOOL_OUTPUT_BYTES};
use peering_wire::agent::{AgentPlanStep, AgentPlanStepStatus, AgentStreamPayload, AgentToolCall};
use serde_json::Value;

const REPLY_CUT: &str = "Part of a reply was too long to show.";

impl CodexStream {
    pub(super) fn item(&mut self, json: &Object, started: bool) -> Vec<AgentStreamPayload> {
        let Some(item) = json.get("item").and_then(Value::as_object) else {
            return Vec::new();
        };
        let (Some(id), Some(kind)) = (str_field(item, "id"), str_field(item, "type")) else {
            return Vec::new();
        };
        match kind.as_str() {
            "agent_message" => agent_message(item, started),
            // Sent whole at completion, and dropped like Claude's thinking.
            "reasoning" => Vec::new(),
            "command_execution" => command(item, id, started),
            "file_change" => file_change(item, id, started),
            "mcp_tool_call" => mcp_tool(item, id, started),
            "web_search" if started => started_call(id, &kind, "Search", str_field(item, "query")),
            "web_search" => vec![finished(id, true, None, false)],
            "todo_list" => todo_list(item, id, started),
            // A non-fatal warning drawn as an item, such as a model-metadata miss.
            "error" if started => Vec::new(),
            "error" => str_field(item, "message").map(|text| vec![notice(&text)]).unwrap_or_default(),
            other => self.ignore(&format!("item/{other}")),
        }
    }
}

/// The whole message at completion; no `item.started` is sent for these.
fn agent_message(item: &Object, started: bool) -> Vec<AgentStreamPayload> {
    let text = str_field(item, "text").unwrap_or_default();
    if started || text.is_empty() {
        return Vec::new();
    }
    let (kept, truncated) = trimmed(&text, MAXIMUM_TOOL_OUTPUT_BYTES);
    let mut payloads = vec![AgentStreamPayload::TextFinal { text: kept }];
    if truncated {
        payloads.push(notice(REPLY_CUT));
    }
    payloads
}

fn command(item: &Object, id: String, started: bool) -> Vec<AgentStreamPayload> {
    if started {
        return started_call(id, "command_execution", "Command", str_field(item, "command"));
    }
    let output = str_field(item, "aggregated_output").unwrap_or_default();
    let (kept, truncated) = trimmed(&output, MAXIMUM_TOOL_OUTPUT_BYTES);
    let exit = item.get("exit_code").and_then(Value::as_i64).unwrap_or(0);
    let ok = completed(item) && exit == 0;
    vec![finished(id, ok, non_empty(kept), truncated)]
}

/// No diff: this CLI's file-change items carry none, so the paths and kinds are what there is to show.
fn file_change(item: &Object, id: String, started: bool) -> Vec<AgentStreamPayload> {
    let changes = object_array(item.get("changes")).unwrap_or_default();
    if started {
        let first = changes.iter().find_map(|change| str_field(change, "path"));
        let mut call = tool_call(id, "file_change", "Edit", first.clone());
        call.file_path = first;
        return vec![AgentStreamPayload::ToolStarted { call }];
    }
    let summary = changes
        .iter()
        .map(|change| {
            let kind = str_field(change, "kind").unwrap_or_else(|| "update".to_owned());
            format!("{kind} {}", str_field(change, "path").unwrap_or_default())
        })
        .collect::<Vec<_>>()
        .join("\n");
    vec![finished(id, completed(item), non_empty(summary), false)]
}

fn mcp_tool(item: &Object, id: String, started: bool) -> Vec<AgentStreamPayload> {
    if started {
        let parts: Vec<String> = ["server", "tool"].iter().filter_map(|key| str_field(item, key)).collect();
        return started_call(id, "mcp_tool_call", "MCP tool", non_empty(parts.join(" · ")));
    }
    let error = str_field(item, "error");
    vec![finished(id, error.is_none(), error, false)]
}

fn todo_list(item: &Object, id: String, started: bool) -> Vec<AgentStreamPayload> {
    if !started {
        return vec![finished(id, true, None, false)];
    }
    let steps: Vec<AgentPlanStep> = object_array(item.get("items"))
        .unwrap_or_default()
        .iter()
        .filter_map(|entry| {
            let done = entry.get("completed").and_then(Value::as_bool) == Some(true);
            Some(AgentPlanStep {
                text: str_field(entry, "text")?,
                status: if done { AgentPlanStepStatus::Completed } else { AgentPlanStepStatus::Pending },
            })
        })
        .collect();
    let detail = non_empty(steps.iter().map(|step| step.text.as_str()).collect::<Vec<_>>().join("; "));
    let mut call = tool_call(id, "todo_list", "Plan", detail);
    call.plan = (!steps.is_empty()).then_some(steps);
    vec![AgentStreamPayload::ToolStarted { call }]
}

fn completed(item: &Object) -> bool {
    str_field(item, "status").as_deref() == Some("completed")
}

fn non_empty(text: String) -> Option<String> {
    (!text.is_empty()).then_some(text)
}

pub(crate) fn tool_call(id: String, name: &str, title: &str, detail: Option<String>) -> AgentToolCall {
    AgentToolCall {
        id,
        name: name.to_owned(),
        title: title.to_owned(),
        detail,
        file_path: None,
        diff: None,
        questions: None,
        plan: None,
    }
}

fn started_call(id: String, name: &str, title: &str, detail: Option<String>) -> Vec<AgentStreamPayload> {
    vec![AgentStreamPayload::ToolStarted { call: tool_call(id, name, title, detail) }]
}

pub(crate) fn finished(call_id: String, ok: bool, output: Option<String>, truncated: bool) -> AgentStreamPayload {
    AgentStreamPayload::ToolFinished { call_id, ok, output, truncated }
}
