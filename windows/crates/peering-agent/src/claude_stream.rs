//! Claude Code's `stream-json` output, read one line at a time into the agent events the phone shows.

mod json;
mod lines;
mod shapes;
mod text;
mod turn;

#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_shapes;

use json::{str_field, Object};
use peering_wire::agent::{AgentStreamPayload, AgentUsage};
use serde_json::Value;
use std::collections::{BTreeSet, HashMap};

const AGENT_ID: &str = "claude";
const UNREADABLE_LINE: &str = "A line of Claude Code's output could not be read.";

/// Stateful reader of one Claude Code process's output. Feed it lines in order.
#[derive(Debug)]
pub struct ClaudeStream {
    cli_session_id: Option<String>,
    model: Option<String>,
    usage: AgentUsage,
    last_total_cost_usd: Option<f64>,
    announced_unknown_kinds: BTreeSet<String>,
    approval_inputs: HashMap<String, Object>,
}

impl Default for ClaudeStream {
    fn default() -> Self {
        Self::new()
    }
}

impl ClaudeStream {
    pub fn new() -> Self {
        Self {
            cli_session_id: None,
            model: None,
            usage: AgentUsage {
                context_used_tokens: None,
                context_window_tokens: None,
                input_tokens: 0,
                cached_tokens: 0,
                output_tokens: 0,
                cost_usd: None,
                limits: Vec::new(),
            },
            last_total_cost_usd: None,
            announced_unknown_kinds: BTreeSet::new(),
            approval_inputs: HashMap::new(),
        }
    }

    pub fn cli_session_id(&self) -> Option<&str> {
        self.cli_session_id.as_deref()
    }

    /// What the session has used, as far as the stream has said. Read after each line.
    pub fn usage(&self) -> &AgentUsage {
        &self.usage
    }

    /// The input a waiting approval asked for, taken once so the answer can echo it back.
    pub fn take_approval_input(&mut self, approval_id: &str) -> Option<Object> {
        self.approval_inputs.remove(approval_id)
    }

    /// Everything the line means, in order. Empty for lines that mean nothing to a reader.
    pub fn feed_line(&mut self, line: &str) -> Vec<AgentStreamPayload> {
        let Some(object) = parse_object(line) else {
            return vec![notice(UNREADABLE_LINE)];
        };
        let Some(kind) = str_field(&object, "type") else {
            return vec![notice(UNREADABLE_LINE)];
        };
        let parent = object
            .get("parent_tool_use_id")
            .and_then(Value::as_str)
            .filter(|parent| !parent.is_empty());
        match parent {
            None => self.route(&kind, &object),
            Some(parent) => {
                if !matches!(kind.as_str(), "assistant" | "user" | "stream_event") {
                    return Vec::new();
                }
                self.route(&kind, &object)
                    .into_iter()
                    .map(|event| AgentStreamPayload::Child {
                        parent_call_id: parent.to_owned(),
                        event: Box::new(event),
                    })
                    .collect()
            }
        }
    }

    fn route(&mut self, kind: &str, object: &Object) -> Vec<AgentStreamPayload> {
        match kind {
            "system" => self.system(object),
            "stream_event" => lines::stream_event(object),
            "assistant" => self.assistant(object),
            "user" => lines::user(object),
            "result" => self.result(object),
            "rate_limit_event" => {
                self.note_limits(object.get("rate_limit_info").and_then(Value::as_object));
                Vec::new()
            }
            "control_request" => self.control_request(object),
            "control_response" | "control_cancel_request" => Vec::new(),
            other => self.ignore(other),
        }
    }

    fn system(&mut self, object: &Object) -> Vec<AgentStreamPayload> {
        match object.get("subtype").and_then(Value::as_str) {
            Some("init") => {
                self.cli_session_id = str_field(object, "session_id");
                self.model = str_field(object, "model");
                vec![AgentStreamPayload::SessionReady {
                    agent_id: AGENT_ID.to_owned(),
                    cli_session_id: self.cli_session_id.clone(),
                    model: self.model.clone(),
                    directory: str_field(object, "cwd").unwrap_or_default(),
                }]
            }
            Some("compact_boundary") => vec![notice("The conversation was compacted to fit.")],
            Some("api_retry") => vec![notice("Claude Code is retrying after an API error.")],
            Some("permission_denied") => vec![notice("Claude Code denied a tool call by its own rules.")],
            Some("task_notification") => lines::task_notification(object),
            _ => Vec::new(),
        }
    }

    fn control_request(&mut self, object: &Object) -> Vec<AgentStreamPayload> {
        let request = object.get("request").and_then(Value::as_object);
        let is_tool_ask = request.and_then(|request| str_field(request, "subtype")).as_deref() == Some("can_use_tool");
        let approval_id = str_field(object, "request_id");
        let tool_name = request.and_then(|request| str_field(request, "tool_name"));
        let (Some(request), true, Some(approval_id), Some(tool_name)) = (request, is_tool_ask, approval_id, tool_name)
        else {
            let subtype = request
                .and_then(|request| str_field(request, "subtype"))
                .unwrap_or_else(|| "?".to_owned());
            return self.ignore(&format!("control_request/{subtype}"));
        };
        let input = request.get("input").and_then(Value::as_object).cloned().unwrap_or_default();
        self.approval_inputs.insert(approval_id.clone(), input.clone());
        let call_id = str_field(request, "tool_use_id").unwrap_or_else(|| approval_id.clone());
        let call = shapes::tool_call(&call_id, &tool_name, &input, str_field(request, "display_name").as_deref());
        let reason = str_field(&input, "description").or_else(|| str_field(request, "decision_reason"));
        vec![AgentStreamPayload::ApprovalRequested {
            approval_id,
            call,
            reason,
        }]
    }

    /// Each unknown kind is said once, so a chatty unknown does not fill the transcript with one line.
    fn ignore(&mut self, kind: &str) -> Vec<AgentStreamPayload> {
        if !self.announced_unknown_kinds.insert(kind.to_owned()) {
            return Vec::new();
        }
        vec![notice(&format!(
            "Claude Code sent something this app does not know how to show ({kind})."
        ))]
    }
}

fn parse_object(line: &str) -> Option<Object> {
    match serde_json::from_str::<Value>(line) {
        Ok(Value::Object(object)) => Some(object),
        _ => None,
    }
}

pub(super) fn notice(text: &str) -> AgentStreamPayload {
    AgentStreamPayload::Notice { text: text.to_owned() }
}
