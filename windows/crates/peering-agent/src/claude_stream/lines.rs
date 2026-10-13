//! The lines that carry an assistant message, a user message, a streamed delta or a finished sub-agent.

use super::json::{int_field, object_array, str_field, Object};
use super::notice;
use super::shapes;
use super::text::{content_text, trimmed, MAXIMUM_TOOL_OUTPUT_BYTES};
use super::ClaudeStream;
use peering_wire::agent::AgentStreamPayload;
use serde_json::Value;

const REPLY_TRUNCATED: &str = "Part of a reply was too long to show.";
/// The Agent tool's launch result is instructions for the model (an agent ID, "do not mention to user", a
/// transcript path), not something to show.
const AGENT_LAUNCH_PREFIX: &str = "Async agent launched successfully";
const USAGE_TOKEN_FIELDS: [&str; 4] = [
    "input_tokens",
    "cache_read_input_tokens",
    "cache_creation_input_tokens",
    "output_tokens",
];

impl ClaudeStream {
    pub(super) fn assistant(&mut self, object: &Object) -> Vec<AgentStreamPayload> {
        let Some(message) = object.get("message").and_then(Value::as_object) else {
            return Vec::new();
        };
        let Some(blocks) = object_array(message.get("content")) else {
            return Vec::new();
        };
        // The size of the conversation at this call, which is what the next call starts from.
        if let Some(used) = message.get("usage").and_then(Value::as_object) {
            let tokens: i64 = USAGE_TOKEN_FIELDS.iter().map(|field| int_field(used, field)).sum();
            if tokens > 0 {
                self.usage.context_used_tokens = Some(tokens);
            }
        }
        blocks.into_iter().flat_map(assistant_block).collect()
    }
}

pub(super) fn stream_event(object: &Object) -> Vec<AgentStreamPayload> {
    let Some(event) = object.get("event").and_then(Value::as_object) else {
        return Vec::new();
    };
    if event.get("type").and_then(Value::as_str) != Some("content_block_delta") {
        return Vec::new();
    }
    let Some(delta) = event.get("delta").and_then(Value::as_object) else {
        return Vec::new();
    };
    if delta.get("type").and_then(Value::as_str) != Some("text_delta") {
        return Vec::new();
    }
    match str_field(delta, "text").filter(|text| !text.is_empty()) {
        Some(text) => vec![AgentStreamPayload::TextDelta { text }],
        None => Vec::new(),
    }
}

pub(super) fn task_notification(object: &Object) -> Vec<AgentStreamPayload> {
    let Some(call_id) = str_field(object, "tool_use_id").filter(|id| !id.is_empty()) else {
        return Vec::new();
    };
    // A background sub-agent's call finishes as it launches; this status is the end of the work itself.
    let ok = object.get("status").and_then(Value::as_str) == Some("completed");
    vec![AgentStreamPayload::ToolFinished {
        call_id,
        ok,
        output: None,
        truncated: false,
    }]
}

pub(super) fn user(object: &Object) -> Vec<AgentStreamPayload> {
    // The CLI echoes the prompt it was sent. The host writes each prompt into the transcript itself, so an echo
    // would tell the same thing twice.
    if object.get("isReplay").and_then(Value::as_bool) == Some(true) {
        return Vec::new();
    }
    let Some(message) = object.get("message").and_then(Value::as_object) else {
        return Vec::new();
    };
    let Some(blocks) = object_array(message.get("content")) else {
        return Vec::new();
    };
    blocks
        .into_iter()
        .filter(|block| block.get("type").and_then(Value::as_str) == Some("tool_result"))
        .filter_map(tool_result)
        .collect()
}

fn assistant_block(block: &Object) -> Vec<AgentStreamPayload> {
    match block.get("type").and_then(Value::as_str) {
        Some("text") => {
            let Some(text) = str_field(block, "text").filter(|text| !text.is_empty()) else {
                return Vec::new();
            };
            let (kept, truncated) = trimmed(&text, MAXIMUM_TOOL_OUTPUT_BYTES);
            let mut payloads = vec![AgentStreamPayload::TextFinal { text: kept }];
            if truncated {
                payloads.push(notice(REPLY_TRUNCATED));
            }
            payloads
        }
        Some("tool_use") => {
            let (Some(id), Some(name)) = (str_field(block, "id"), str_field(block, "name")) else {
                return Vec::new();
            };
            let input = block.get("input").and_then(Value::as_object).cloned().unwrap_or_default();
            vec![AgentStreamPayload::ToolStarted {
                call: shapes::tool_call(&id, &name, &input, None),
            }]
        }
        _ => Vec::new(),
    }
}

fn tool_result(block: &Object) -> Option<AgentStreamPayload> {
    let call_id = str_field(block, "tool_use_id")?;
    let ok = block.get("is_error").and_then(Value::as_bool) != Some(true);
    let output = content_text(block.get("content"));
    if output.starts_with(AGENT_LAUNCH_PREFIX) {
        return Some(AgentStreamPayload::ToolFinished {
            call_id,
            ok,
            output: None,
            truncated: false,
        });
    }
    let (kept, truncated) = trimmed(&output, MAXIMUM_TOOL_OUTPUT_BYTES);
    Some(AgentStreamPayload::ToolFinished {
        call_id,
        ok,
        output: (!kept.is_empty()).then_some(kept),
        truncated,
    })
}
