//! OpenCode's `run --format json` lines, read into the agent events the phone shows. Mirrors PeeringKit's
//! `AgentOpenCodeStream`.

mod tools;

#[cfg(test)]
mod tests;

use crate::claude_stream::json::{int_field, str_field, Object};
use crate::claude_stream::text::{trimmed, MAXIMUM_TOOL_OUTPUT_BYTES};
use peering_wire::agent::{AgentStreamPayload, AgentTurnSummary, AgentUsage};
use serde_json::Value;
use std::collections::BTreeSet;

pub const AGENT_ID: &str = "opencode";
const UNREADABLE_LINE: &str = "A line of OpenCode's output could not be read.";

#[derive(Debug, Default)]
pub struct OpenCodeStream {
    directory: String,
    cli_session_id: Option<String>,
    /// The context window is not in the stream; the adapter would fill it from the model's own listing.
    usage: AgentUsage,
    in_turn: bool,
    turn_input_tokens: i64,
    turn_output_tokens: i64,
    announced_unknown_names: BTreeSet<String>,
}

impl OpenCodeStream {
    pub fn new(directory: &str, cli_session_id: Option<String>) -> Self {
        Self {
            directory: directory.to_owned(),
            cli_session_id,
            ..Self::default()
        }
    }

    pub fn cli_session_id(&self) -> Option<&str> {
        self.cli_session_id.as_deref()
    }

    pub fn usage(&self) -> &AgentUsage {
        &self.usage
    }

    pub fn feed_line(&mut self, line: &str) -> Vec<AgentStreamPayload> {
        let parsed = serde_json::from_str::<Value>(line).ok().and_then(|value| value.as_object().cloned());
        let Some(json) = parsed else {
            return vec![notice(UNREADABLE_LINE)];
        };
        let Some(kind) = str_field(&json, "type") else {
            return vec![notice(UNREADABLE_LINE)];
        };
        let mut payloads = self.note_session(&json);
        let empty = Object::new();
        let part = json.get("part").and_then(Value::as_object).unwrap_or(&empty);
        match kind.as_str() {
            "step_start" => payloads.extend(self.begin_turn()),
            "text" => payloads.extend(self.text(part)),
            "tool_use" => {
                payloads.extend(self.begin_turn());
                payloads.extend(tools::tool(part));
            }
            "step_finish" => payloads.extend(self.step_finished(part)),
            "error" => {
                payloads.extend(self.begin_turn());
                payloads.push(AgentStreamPayload::Notice { text: error_text(json.get("error")) });
                payloads.push(self.finish_turn(false));
            }
            "reasoning" => {}
            other => payloads.extend(self.ignore(&format!("line/{other}"))),
        }
        payloads
    }

    /// Every line names the session; a new name is announced as the session being ready.
    fn note_session(&mut self, json: &Object) -> Vec<AgentStreamPayload> {
        let Some(id) = str_field(json, "sessionID") else {
            return Vec::new();
        };
        if self.cli_session_id.as_deref() == Some(id.as_str()) {
            return Vec::new();
        }
        self.cli_session_id = Some(id.clone());
        vec![AgentStreamPayload::SessionReady {
            agent_id: AGENT_ID.to_owned(),
            cli_session_id: Some(id),
            model: None,
            directory: self.directory.clone(),
        }]
    }

    fn text(&mut self, part: &Object) -> Vec<AgentStreamPayload> {
        let text = str_field(part, "text").unwrap_or_default();
        if text.is_empty() {
            return Vec::new();
        }
        let mut payloads = self.begin_turn();
        let (kept, truncated) = trimmed(&text, MAXIMUM_TOOL_OUTPUT_BYTES);
        payloads.push(AgentStreamPayload::TextFinal { text: kept });
        if truncated {
            payloads.push(notice("Part of a reply was too long to show."));
        }
        payloads
    }

    /// A step that ends to run tools is not the end of the turn.
    fn step_finished(&mut self, part: &Object) -> Vec<AgentStreamPayload> {
        if let Some(tokens) = part.get("tokens").and_then(Value::as_object) {
            self.turn_input_tokens += int_field(tokens, "input");
            self.turn_output_tokens += int_field(tokens, "output");
            self.note_step_usage(tokens);
        }
        if str_field(part, "reason").as_deref() == Some("tool-calls") {
            return Vec::new();
        }
        let mut payloads = self.begin_turn();
        payloads.push(self.finish_turn(true));
        payloads
    }

    fn note_step_usage(&mut self, tokens: &Object) {
        let cache = tokens.get("cache").and_then(Value::as_object);
        let input = int_field(tokens, "input");
        let read = cache.map(|cache| int_field(cache, "read")).unwrap_or(0);
        let write = cache.map(|cache| int_field(cache, "write")).unwrap_or(0);
        let output = int_field(tokens, "output");
        self.usage.input_tokens += input + write;
        self.usage.cached_tokens += read;
        self.usage.output_tokens += output;
        self.usage.context_used_tokens = Some(input + read + write + output);
    }

    fn begin_turn(&mut self) -> Vec<AgentStreamPayload> {
        if self.in_turn {
            return Vec::new();
        }
        self.in_turn = true;
        vec![AgentStreamPayload::TurnStarted {}]
    }

    fn finish_turn(&mut self, ok: bool) -> AgentStreamPayload {
        let positive = |tokens: i64| (tokens > 0).then_some(tokens);
        let summary = AgentTurnSummary {
            ok,
            stopped: false,
            cost_usd: None,
            input_tokens: positive(self.turn_input_tokens),
            output_tokens: positive(self.turn_output_tokens),
            duration: None,
            model: None,
        };
        self.in_turn = false;
        self.turn_input_tokens = 0;
        self.turn_output_tokens = 0;
        AgentStreamPayload::TurnFinished { summary }
    }

    fn ignore(&mut self, name: &str) -> Vec<AgentStreamPayload> {
        if !self.announced_unknown_names.insert(name.to_owned()) {
            return Vec::new();
        }
        vec![notice(&format!("OpenCode sent something this app does not know how to show ({name})."))]
    }
}

fn error_text(value: Option<&Value>) -> String {
    let Some(object) = value.and_then(Value::as_object) else {
        return "OpenCode reported an error.".to_owned();
    };
    let message = object.get("data").and_then(Value::as_object).and_then(|data| str_field(data, "message"));
    match (message, str_field(object, "name")) {
        (Some(message), _) if !message.is_empty() => message,
        (_, Some(name)) => format!("OpenCode reported an error ({name})."),
        _ => "OpenCode reported an error.".to_owned(),
    }
}

fn notice(text: &str) -> AgentStreamPayload {
    AgentStreamPayload::Notice { text: text.to_owned() }
}
