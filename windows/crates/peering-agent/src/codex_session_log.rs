//! What Codex writes about a thread's usage in its own session log, which `exec --json` does not repeat: the context
//! window, the conversation's size now, and the account's rate-limit windows. The log is
//! `<codex home>/sessions/<y>/<m>/<d>/rollout-...-<thread id>.jsonl`; its last `token_count` event is the answer.

mod lookup;
#[cfg(test)]
mod tests;

pub use lookup::LogLookup;

use crate::claude_stream::json::{int_field, Object};
use peering_wire::agent::{AgentUsage, AgentUsageLimit};
use serde_json::Value;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

const UNIX_TO_REFERENCE_SECONDS: f64 = 978_307_200.0;
/// Far more than the few hundred bytes the answer needs; a long thread's log is megabytes.
const TAIL_BYTES: u64 = 512 * 1024;
const LIMIT_KEYS: [&str; 2] = ["primary", "secondary"];

/// The usage in the last `token_count` event of a log's text, or `None` when it holds none.
pub fn usage_from_log(text: &str) -> Option<AgentUsage> {
    let payload = text
        .lines()
        .rev()
        .filter(|line| line.contains("\"token_count\""))
        .find_map(token_count_payload)?;
    let mut usage = AgentUsage::default();
    if let Some(info) = payload.get("info").and_then(Value::as_object) {
        if let Some(total) = info.get("total_token_usage").and_then(Value::as_object) {
            let cached = int_field(total, "cached_input_tokens");
            usage.input_tokens = (int_field(total, "input_tokens") - cached).max(0);
            usage.cached_tokens = cached;
            usage.output_tokens = int_field(total, "output_tokens");
        }
        usage.context_window_tokens = info.get("model_context_window").and_then(Value::as_i64);
        usage.context_used_tokens = info
            .get("last_token_usage")
            .and_then(|last| last.get("total_tokens"))
            .and_then(Value::as_i64);
    }
    let limits = payload.get("rate_limits").and_then(Value::as_object);
    usage.limits = LIMIT_KEYS
        .iter()
        .filter_map(|key| limit(limits?.get(*key)?.as_object()?))
        .collect();
    Some(usage)
}

fn token_count_payload(line: &str) -> Option<Object> {
    let value: Value = serde_json::from_str(line).ok()?;
    let payload = value.get("payload")?.as_object()?;
    (payload.get("type")?.as_str()? == "token_count").then(|| payload.clone())
}

fn limit(window: &Object) -> Option<AgentUsageLimit> {
    let percent = window.get("used_percent")?.as_f64()?;
    let minutes = window.get("window_minutes")?.as_i64()?;
    Some(AgentUsageLimit {
        label: label_for_minutes(minutes),
        used_fraction: (percent / 100.0).clamp(0.0, 1.0),
        resets_at: window
            .get("resets_at")
            .and_then(Value::as_f64)
            .map(|unix| unix - UNIX_TO_REFERENCE_SECONDS),
    })
}

/// "5 hours", "7 days", "30 days": the window as a person says it.
pub fn label_for_minutes(minutes: i64) -> String {
    let (count, unit) = if minutes >= 1440 && minutes % 1440 == 0 {
        (minutes / 1440, "day")
    } else if minutes >= 60 && minutes % 60 == 0 {
        (minutes / 60, "hour")
    } else {
        (minutes, "minute")
    };
    if count == 1 {
        format!("1 {unit}")
    } else {
        format!("{count} {unit}s")
    }
}

/// Finds and reads a thread's log under `sessions`, remembering where it was, or that it was not there, in `lookup`.
pub fn read_usage(sessions: &Path, thread: &str, lookup: &mut LogLookup) -> Option<AgentUsage> {
    let mut file = File::open(lookup.find(sessions, thread)?).ok()?;
    let size = file.seek(SeekFrom::End(0)).ok()?;
    file.seek(SeekFrom::Start(size.saturating_sub(TAIL_BYTES))).ok()?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).ok()?;
    usage_from_log(&String::from_utf8_lossy(&bytes))
}

/// `CODEX_HOME`, or `.codex` in the user's home folder.
pub fn codex_home(codex_home: Option<&str>, home: &str) -> PathBuf {
    match codex_home {
        Some(path) if !path.is_empty() => PathBuf::from(path),
        _ => Path::new(home).join(".codex"),
    }
}

/// The models Codex lists in its own cache, which the CLI refreshes; no command prints them.
pub fn visible_models(cache_json: &str) -> Vec<String> {
    let Ok(root) = serde_json::from_str::<Value>(cache_json) else {
        return Vec::new();
    };
    root.get("models")
        .and_then(Value::as_array)
        .map(|models| {
            models
                .iter()
                .filter(|entry| entry.get("visibility").and_then(Value::as_str) == Some("list"))
                .filter_map(|entry| entry.get("slug")?.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}
