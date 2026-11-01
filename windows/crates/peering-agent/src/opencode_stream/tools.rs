//! One OpenCode `tool_use` part. The CLI reports a tool once, finished, so it becomes a start and a finish together.

use crate::claude_stream::json::{object_array, str_field, Object};
use crate::claude_stream::text::{trimmed, MAXIMUM_TOOL_OUTPUT_BYTES};
use crate::codex_stream::items::{finished, tool_call};
use peering_wire::agent::{AgentPlanStep, AgentPlanStepStatus, AgentStreamPayload};
use serde_json::Value;

/// Tools whose output is the file itself or the plan, which the card already shows.
const QUIET_TOOLS: [&str; 7] = ["read", "write", "edit", "patch", "multiedit", "todowrite", "todoread"];

pub(super) fn tool(part: &Object) -> Vec<AgentStreamPayload> {
    let Some(name) = str_field(part, "tool") else {
        return Vec::new();
    };
    let Some(id) = str_field(part, "callID").or_else(|| str_field(part, "id")) else {
        return Vec::new();
    };
    let empty = Object::new();
    let state = part.get("state").and_then(Value::as_object).unwrap_or(&empty);
    let input = state.get("input").and_then(Value::as_object).unwrap_or(&empty);
    let file_path = str_field(input, "filePath");
    let (title, detail) = title_and_detail(&name, input, file_path.clone());

    let mut call = tool_call(id.clone(), &name, &title, detail);
    call.file_path = file_path;
    call.plan = plan(&name, input);
    call.diff = diff(&name, state);

    let ok = str_field(state, "status").as_deref() == Some("completed");
    let raw = if !ok {
        str_field(state, "error")
    } else if QUIET_TOOLS.contains(&name.as_str()) {
        None
    } else {
        str_field(state, "output")
    };
    let (kept, truncated) = raw.map(|text| trimmed(&text, MAXIMUM_TOOL_OUTPUT_BYTES)).unwrap_or_default();
    let output = (!kept.is_empty()).then_some(kept);
    vec![AgentStreamPayload::ToolStarted { call }, finished(id, ok, output, truncated)]
}

fn title_and_detail(name: &str, input: &Object, file_path: Option<String>) -> (String, Option<String>) {
    let (title, detail) = match name {
        "bash" => ("Command", str_field(input, "command")),
        "read" => ("Read", file_path),
        "write" => ("Write", file_path),
        "edit" | "patch" | "multiedit" => ("Edit", file_path),
        "glob" | "grep" => ("Search", str_field(input, "pattern")),
        "list" => ("List", str_field(input, "path")),
        "webfetch" => ("Fetch", str_field(input, "url")),
        "task" => ("Agent", str_field(input, "description")),
        "todowrite" | "todoread" => ("Plan", None),
        _ => return (capitalised(name), None),
    };
    (title.to_owned(), detail)
}

fn capitalised(name: &str) -> String {
    let mut characters = name.chars();
    characters
        .next()
        .map(|first| first.to_uppercase().chain(characters).collect())
        .unwrap_or_default()
}

fn plan(name: &str, input: &Object) -> Option<Vec<AgentPlanStep>> {
    if name != "todowrite" {
        return None;
    }
    let steps: Vec<AgentPlanStep> = object_array(input.get("todos"))?
        .iter()
        .filter_map(|todo| {
            Some(AgentPlanStep {
                text: str_field(todo, "content")?,
                status: AgentPlanStepStatus::from_raw(str_field(todo, "status").as_deref()),
            })
        })
        .collect();
    (!steps.is_empty()).then_some(steps)
}

fn diff(name: &str, state: &Object) -> Option<String> {
    if name != "edit" {
        return None;
    }
    let unified = state.get("metadata")?.as_object().and_then(|metadata| str_field(metadata, "diff"))?;
    Some(trimmed(&unified, MAXIMUM_TOOL_OUTPUT_BYTES).0)
}
