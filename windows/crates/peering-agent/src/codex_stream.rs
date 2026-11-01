//! Codex's `exec --json` lines, read into the agent events the phone shows. Mirrors PeeringKit's `AgentCodexStream`.

pub(crate) mod items;

#[cfg(test)]
mod tests;

use crate::claude_stream::json::{int_field, str_field, Object};
use peering_wire::agent::{AgentStreamPayload, AgentTurnSummary, AgentUsage};
use serde_json::Value;
use std::collections::BTreeSet;

pub const AGENT_ID: &str = "codex";
const UNREADABLE_LINE: &str = "A line of Codex's output could not be read.";
const GENERIC_ERROR: &str = "Codex reported an error.";

#[derive(Debug, Default)]
pub struct CodexStream {
    /// Codex never names the folder: it is the working directory the host spawned it in.
    directory: String,
    cli_session_id: Option<String>,
    /// Totals from the turn reports, superseded by the session log where it can be read.
    usage: AgentUsage,
    announced_unknown_names: BTreeSet<String>,
    last_error_message: Option<String>,
}

impl CodexStream {
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
        let parsed: Option<Object> = serde_json::from_str::<Value>(line)
            .ok()
            .and_then(|value| value.as_object().cloned());
        let Some(json) = parsed else {
            return vec![notice(UNREADABLE_LINE)];
        };
        let Some(kind) = str_field(&json, "type") else {
            return vec![notice(UNREADABLE_LINE)];
        };
        match kind.as_str() {
            "thread.started" => {
                self.cli_session_id = str_field(&json, "thread_id");
                vec![AgentStreamPayload::SessionReady {
                    agent_id: AGENT_ID.to_owned(),
                    cli_session_id: self.cli_session_id.clone(),
                    model: None,
                    directory: self.directory.clone(),
                }]
            }
            "turn.started" => vec![AgentStreamPayload::TurnStarted {}],
            "item.started" => self.item(&json, true),
            "item.completed" => self.item(&json, false),
            "item.updated" => Vec::new(),
            "turn.completed" => vec![self.turn_completed(&json)],
            "turn.failed" => {
                let message = error_text(json.get("error"));
                let mut payloads = vec![AgentStreamPayload::TurnFinished {
                    summary: summary(false, None, None),
                }];
                payloads.extend(self.fresh_error(message));
                payloads
            }
            "error" => self.fresh_error(error_text(Some(&Value::Object(json.clone())))),
            other => self.ignore(&format!("line/{other}")),
        }
    }

    fn turn_completed(&mut self, json: &Object) -> AgentStreamPayload {
        let usage = json.get("usage").and_then(Value::as_object);
        let input = usage.map(|usage| int_field(usage, "input_tokens")).unwrap_or(0);
        let cached = usage.map(|usage| int_field(usage, "cached_input_tokens")).unwrap_or(0);
        let output = usage.map(|usage| int_field(usage, "output_tokens")).unwrap_or(0);
        self.usage.input_tokens += (input - cached).max(0);
        self.usage.cached_tokens += cached;
        self.usage.output_tokens += output;
        let reported = |key: &str| usage.and_then(|usage| usage.get(key)).and_then(Value::as_i64);
        AgentStreamPayload::TurnFinished {
            summary: summary(true, reported("input_tokens"), reported("output_tokens")),
        }
    }

    /// The CLI repeats one error as an `error` line and a `turn.failed`; the phone is told once.
    fn fresh_error(&mut self, message: String) -> Vec<AgentStreamPayload> {
        if self.last_error_message.as_deref() == Some(message.as_str()) {
            return Vec::new();
        }
        self.last_error_message = Some(message.clone());
        vec![AgentStreamPayload::Notice { text: message }]
    }

    fn ignore(&mut self, name: &str) -> Vec<AgentStreamPayload> {
        if !self.announced_unknown_names.insert(name.to_owned()) {
            return Vec::new();
        }
        vec![notice(&format!(
            "Codex sent something this app does not know how to show ({name})."
        ))]
    }
}

/// The message is sometimes a JSON document of its own, whose `error.message` is the readable part.
fn error_text(value: Option<&Value>) -> String {
    let Some(raw) = value.and_then(Value::as_object).and_then(|object| str_field(object, "message")) else {
        return GENERIC_ERROR.to_owned();
    };
    serde_json::from_str::<Value>(&raw)
        .ok()
        .and_then(|nested| nested.get("error")?.get("message")?.as_str().map(str::to_owned))
        .unwrap_or(raw)
}

fn summary(ok: bool, input_tokens: Option<i64>, output_tokens: Option<i64>) -> AgentTurnSummary {
    AgentTurnSummary {
        ok,
        stopped: false,
        cost_usd: None,
        input_tokens,
        output_tokens,
        duration: None,
        model: None,
    }
}

fn notice(text: &str) -> AgentStreamPayload {
    AgentStreamPayload::Notice { text: text.to_owned() }
}
