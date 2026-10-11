//! Control requests this side sends (model, mode, interrupt) and the CLI's answers to them.

use super::arguments::cli_mode_name;
use super::{ClaudeAdapter, PendingRequest, PERMISSION_MODES};
use crate::claude_stream::notice;
use peering_wire::agent::{AgentPermissionMode, AgentStreamPayload};
use serde_json::{json, Map, Value};

/// `Ok` carries the response body; `Err` carries the CLI's error text when it gave one.
type Outcome = Result<Option<Map<String, Value>>, Option<String>>;

impl ClaudeAdapter {
    /// `None` is the CLI's own default. The model that takes effect is reported by `model()` once confirmed.
    pub fn set_model(&mut self, model: Option<&str>) -> bool {
        let fields = match model {
            Some(model) => json!({"model": model}),
            None => json!({}),
        };
        let pending = PendingRequest::SetModel {
            requested: model.map(str::to_owned),
        };
        self.control("set_model", fields, Some(pending))
    }

    pub fn set_permission_mode(&mut self, mode: AgentPermissionMode) -> bool {
        PERMISSION_MODES.contains(&mode) && self.apply_mode(mode)
    }

    pub fn interrupt(&mut self) -> bool {
        self.control("interrupt", json!({}), None)
    }

    pub(super) fn apply_mode(&mut self, mode: AgentPermissionMode) -> bool {
        let fields = json!({"mode": cli_mode_name(mode)});
        self.control("set_permission_mode", fields, Some(PendingRequest::SetMode(mode)))
    }

    fn control(&mut self, subtype: &str, fields: Value, pending: Option<PendingRequest>) -> bool {
        self.next_request += 1;
        let request_id = format!("peering-{}", self.next_request);
        let mut request = fields;
        request["subtype"] = json!(subtype);
        let line = json!({"type": "control_request", "request_id": request_id.clone(), "request": request});
        let sent = self.send(&line);
        if let (true, Some(pending)) = (sent, pending) {
            self.pending.insert(request_id, pending);
        }
        sent
    }

    /// The answer to one of this side's own control requests, if `line` is one. Those answers never reach the
    /// transcript, so they yield only what they mean (a failure notice), or nothing.
    pub(super) fn take_control_response(&mut self, line: &str) -> Option<Vec<AgentStreamPayload>> {
        let value: Value = serde_json::from_str(line).ok()?;
        if value.get("type").and_then(Value::as_str) != Some("control_response") {
            return None;
        }
        let response = value.get("response")?.as_object()?;
        let request_id = response.get("request_id")?.as_str()?;
        let pending = self.pending.remove(request_id)?;
        let outcome: Outcome = if response.get("subtype").and_then(Value::as_str) == Some("success") {
            Ok(response.get("response").and_then(Value::as_object).cloned())
        } else {
            Err(error_text(response))
        };
        Some(match pending {
            PendingRequest::SetModel { requested } => self.model_answer(requested, outcome),
            PendingRequest::SetMode(mode) => self.mode_answer(mode, outcome),
        })
    }

    fn model_answer(&mut self, requested: Option<String>, outcome: Outcome) -> Vec<AgentStreamPayload> {
        match outcome {
            Ok(body) => {
                // The CLI names the model it resolved (`sonnet` comes back as a dated full name).
                self.model = body
                    .as_ref()
                    .and_then(|body| body.get("model"))
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .or(requested);
                Vec::new()
            }
            Err(message) => vec![notice(message.as_deref().unwrap_or("That model was not accepted."))],
        }
    }

    fn mode_answer(&mut self, mode: AgentPermissionMode, outcome: Outcome) -> Vec<AgentStreamPayload> {
        match outcome {
            Ok(_) => {
                // Approving a plan returns to the mode that was in force before it.
                if mode == AgentPermissionMode::Plan && self.permission_mode != AgentPermissionMode::Plan {
                    self.mode_before_plan = self.permission_mode;
                }
                self.permission_mode = mode;
                Vec::new()
            }
            Err(message) => vec![notice(message.as_deref().unwrap_or("That mode was not accepted."))],
        }
    }
}

fn error_text(response: &Map<String, Value>) -> Option<String> {
    let direct = response.get("error").and_then(Value::as_str);
    let nested = response
        .get("response")
        .and_then(|body| body.get("error"))
        .and_then(Value::as_str);
    direct.or(nested).map(str::to_owned)
}
