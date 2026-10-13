//! One tool call as its card draws it: the question, plan and generic shapes Claude's tools take.

use super::json::{object_array, str_field, Object};
use super::text::replacement_diff;
use peering_wire::agent::{AgentPlanStep, AgentPlanStepStatus, AgentQuestion, AgentToolCall, AgentToolOption};

pub fn tool_call(id: &str, name: &str, input: &Object, display_name: Option<&str>) -> AgentToolCall {
    if name == "AskUserQuestion" {
        if let Some(call) = ask_user_question(id, name, input) {
            return call;
        }
    }
    if name == "ExitPlanMode" {
        return AgentToolCall {
            detail: str_field(input, "plan"),
            ..bare(id, name, "Plan")
        };
    }
    if name == "TodoWrite" {
        if let Some(todos) = object_array(input.get("todos")) {
            return plan_call(id, name, &todos);
        }
    }
    generic_call(id, name, input, display_name)
}

fn bare(id: &str, name: &str, title: &str) -> AgentToolCall {
    AgentToolCall {
        id: id.to_owned(),
        name: name.to_owned(),
        title: title.to_owned(),
        detail: None,
        file_path: None,
        diff: None,
        questions: None,
        plan: None,
    }
}

fn ask_user_question(id: &str, name: &str, input: &Object) -> Option<AgentToolCall> {
    let asked = object_array(input.get("questions"))?;
    let questions: Vec<AgentQuestion> = asked.into_iter().filter_map(question).collect();
    let first = questions.first();
    let title = first
        .and_then(|question| question.header.clone())
        .unwrap_or_else(|| "Question".to_owned());
    let detail = first.map(|question| question.question.clone());
    Some(AgentToolCall {
        title,
        detail,
        questions: (!questions.is_empty()).then_some(questions),
        ..bare(id, name, "")
    })
}

fn question(entry: &Object) -> Option<AgentQuestion> {
    let question = str_field(entry, "question")?;
    let options = object_array(entry.get("options"))
        .unwrap_or_default()
        .into_iter()
        .filter_map(option)
        .collect();
    Some(AgentQuestion {
        header: str_field(entry, "header"),
        question,
        options,
    })
}

fn option(entry: &Object) -> Option<AgentToolOption> {
    Some(AgentToolOption {
        label: str_field(entry, "label")?,
        detail: str_field(entry, "description"),
    })
}

fn plan_call(id: &str, name: &str, todos: &[&Object]) -> AgentToolCall {
    let steps: Vec<AgentPlanStep> = todos
        .iter()
        .filter_map(|todo| {
            let text = str_field(todo, "content")?;
            let status = AgentPlanStepStatus::from_raw(todo.get("status").and_then(|raw| raw.as_str()));
            Some(AgentPlanStep { text, status })
        })
        .collect();
    AgentToolCall {
        plan: (!steps.is_empty()).then_some(steps),
        ..bare(id, name, "Plan")
    }
}

fn generic_call(id: &str, name: &str, input: &Object, display_name: Option<&str>) -> AgentToolCall {
    let file_path = str_field(input, "file_path");
    let detail = detail_for(name, input, file_path.as_deref());
    let diff = match (name, str_field(input, "old_string"), str_field(input, "new_string")) {
        ("Edit", Some(old), Some(new)) => Some(replacement_diff(&old, &new, file_path.as_deref())),
        _ => None,
    };
    let title = display_name
        .filter(|title| !title.is_empty())
        .unwrap_or(name)
        .to_owned();
    AgentToolCall {
        detail,
        file_path,
        diff,
        ..bare(id, name, &title)
    }
}

fn detail_for(name: &str, input: &Object, file_path: Option<&str>) -> Option<String> {
    let key = match name {
        "Bash" => "command",
        "Read" | "Write" | "Edit" | "NotebookEdit" => return file_path.map(str::to_owned),
        "Glob" | "Grep" => "pattern",
        "WebFetch" => "url",
        "WebSearch" => "query",
        "Task" => "description",
        _ => return None,
    };
    str_field(input, key)
}
