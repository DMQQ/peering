//! A finished turn: its summary, and the usage and rate limits the stream reports alongside it.

use super::json::{int_field, str_field, Object};
use super::notice;
use super::text::trimmed;
use super::ClaudeStream;
use peering_wire::agent::{AgentStreamPayload, AgentTurnSummary, AgentUsageLimit};
use serde_json::Value;

const FAILURE_REASON_BYTES: usize = 600;
const LIMIT_ORDER: [&str; 2] = ["five_hour", "seven_day"];
/// The wire's `resets_at` is seconds since 2001-01-01, the reference date Swift's default `Date` encoding uses.
const UNIX_TO_REFERENCE_SECONDS: f64 = 978_307_200.0;

impl ClaudeStream {
    pub(super) fn result(&mut self, object: &Object) -> Vec<AgentStreamPayload> {
        let total = object.get("total_cost_usd").and_then(Value::as_f64);
        let cost = total.map(|total| self.turn_cost(total));
        let usage = object.get("usage").and_then(Value::as_object);
        let model_usage = object.get("modelUsage").and_then(Value::as_object);
        self.note_turn_usage(usage, total, model_usage);

        let terminal_reason = str_field(object, "terminal_reason");
        let ok = object.get("is_error").and_then(Value::as_bool) != Some(true);
        let summary = AgentTurnSummary {
            ok,
            stopped: terminal_reason.is_some_and(|reason| reason.starts_with("aborted")),
            cost_usd: cost,
            input_tokens: usage.and_then(|usage| usage.get("input_tokens")).and_then(Value::as_i64),
            output_tokens: usage.and_then(|usage| usage.get("output_tokens")).and_then(Value::as_i64),
            duration: object
                .get("duration_ms")
                .and_then(Value::as_f64)
                .map(|milliseconds| milliseconds / 1000.0),
            model: model_usage
                .and_then(|models| models.keys().next().cloned())
                .or_else(|| self.model.clone()),
        };
        // The reason a turn failed (a full context, an expired login) is in `result`; without it the turn only reads as failed.
        let reason = str_field(object, "result")
            .map(|reason| reason.trim().to_owned())
            .filter(|reason| !reason.is_empty());
        if let (false, false, Some(reason)) = (summary.ok, summary.stopped, reason) {
            let (kept, _) = trimmed(&reason, FAILURE_REASON_BYTES);
            return vec![notice(&kept), AgentStreamPayload::TurnFinished { summary }];
        }
        vec![AgentStreamPayload::TurnFinished { summary }]
    }

    /// Cumulative cost arrives per session; a turn's cost is the difference from the previous total.
    fn turn_cost(&mut self, total: f64) -> f64 {
        let cost = match self.last_total_cost_usd {
            Some(last) if total >= last => total - last,
            _ => total,
        };
        self.last_total_cost_usd = Some(total);
        cost
    }

    /// A turn's tokens are added to the session's; the cost is already the session's running total.
    fn note_turn_usage(&mut self, turn: Option<&Object>, cumulative_cost: Option<f64>, model_usage: Option<&Object>) {
        if let Some(turn) = turn {
            self.usage.input_tokens = self
                .usage
                .input_tokens
                .saturating_add(int_field(turn, "input_tokens"))
                .saturating_add(int_field(turn, "cache_creation_input_tokens"));
            self.usage.cached_tokens = self
                .usage
                .cached_tokens
                .saturating_add(int_field(turn, "cache_read_input_tokens"));
            self.usage.output_tokens = self
                .usage
                .output_tokens
                .saturating_add(int_field(turn, "output_tokens"));
        }
        if let Some(cost) = cumulative_cost {
            self.usage.cost_usd = Some(cost);
        }
        let window = model_usage
            .and_then(|models| models.values().next())
            .and_then(Value::as_object)
            .and_then(|entry| entry.get("contextWindow"))
            .and_then(Value::as_i64);
        if let Some(window) = window {
            self.usage.context_window_tokens = Some(window);
        }
    }

    pub(super) fn note_limits(&mut self, info: Option<&Object>) {
        let Some(windows) = info
            .and_then(|info| info.get("unifiedWindows"))
            .and_then(Value::as_object)
        else {
            return;
        };
        let mut keys: Vec<&String> = windows.keys().collect();
        keys.sort_by(|a, b| (limit_rank(a), a).cmp(&(limit_rank(b), b)));
        self.usage.limits = keys
            .into_iter()
            .filter_map(|key| limit(key, windows.get(key)?.as_object()?))
            .collect();
    }
}

fn limit_rank(key: &str) -> usize {
    LIMIT_ORDER
        .iter()
        .position(|known| *known == key)
        .unwrap_or(LIMIT_ORDER.len())
}

fn limit(key: &str, window: &Object) -> Option<AgentUsageLimit> {
    let used = window.get("utilization").and_then(Value::as_f64)?;
    let label = match key {
        "five_hour" => "5 hours".to_owned(),
        "seven_day" => "7 days".to_owned(),
        other => other.replace('_', " "),
    };
    Some(AgentUsageLimit {
        label,
        used_fraction: used.clamp(0.0, 1.0),
        resets_at: window
            .get("resetsAt")
            .and_then(Value::as_f64)
            .map(|unix| unix - UNIX_TO_REFERENCE_SECONDS),
    })
}
