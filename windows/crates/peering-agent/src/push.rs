//! What an agent chat pushes to a phone that is not looking at it, as `AgentSessionManager+Events.swift` and
//! `AgentNotificationText.swift` decide on the Mac: a push when the agent asks for approval (even while the phone is
//! connected, because iOS may have suspended it) and one when a turn ends (only when the phone is not in the foreground).
//! The words are English; the Mac localises them to its own language.

use std::collections::{HashMap, HashSet};

use peering_wire::agent::{AgentStreamPayload, AgentToolCall, AgentTurnSummary};

const MAXIMUM_BODY_CHARACTERS: usize = 240;
const MAXIMUM_OPTION_ACTIONS: usize = 4;
const FIRST_LINE_CHARACTERS: usize = 140;
/// A turn shorter than this is not worth saying how long it took.
const WORTH_SAYING_SECONDS: f64 = 5.0;

pub const TOOL_CATEGORY: &str = "peering.agent.approval.tool";
pub const OPEN_CATEGORY: &str = "peering.agent.approval.open";
pub const YES_NO_CATEGORY: &str = "peering.agent.approval.yesno";
pub const FINISHED_CATEGORY: &str = "peering.agent.finished";

/// The buttons a push can name, and the ids a tap on one comes back with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushAction {
    pub category: &'static str,
    pub session_id: String,
    /// Empty for a finished turn.
    pub approval_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentPush {
    pub title: String,
    pub body: String,
    pub action: Option<PushAction>,
}

/// Where the phone that owns a chat is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Reach {
    /// The phone registered a push token.
    pub has_token: bool,
    /// The phone is connected and drawing, so its app already shows what a push would say.
    pub foreground: bool,
}

#[derive(Debug, Default)]
struct Turn {
    last_reply: Option<String>,
    edited_files: HashSet<String>,
}

#[derive(Debug, Default)]
pub struct AgentPushPlanner {
    turns: HashMap<String, Turn>,
}

impl AgentPushPlanner {
    /// Takes one live event of a chat and says what to push for it. `agent_name` is how the pushes call the agent.
    pub fn observe(&mut self, session_id: &str, payload: &AgentStreamPayload, agent_name: &str, reach: Reach) -> Option<AgentPush> {
        let turn = self.turns.entry(session_id.to_owned()).or_default();
        match payload {
            AgentStreamPayload::TurnStarted {} => {
                turn.edited_files.clear();
                None
            }
            AgentStreamPayload::ToolStarted { call } => {
                if edits(call) {
                    if let Some(path) = &call.file_path {
                        turn.edited_files.insert(path.clone());
                    }
                }
                None
            }
            AgentStreamPayload::TextFinal { text } => {
                turn.last_reply = Some(text.clone());
                None
            }
            AgentStreamPayload::ApprovalRequested { approval_id, call, reason } => {
                reach.has_token.then(|| approval(session_id, approval_id, call, reason.as_deref(), agent_name))
            }
            AgentStreamPayload::TurnFinished { summary } => {
                let finished = reach.has_token && !reach.foreground;
                let push = finished.then(|| finished_push(session_id, summary, turn, agent_name));
                turn.edited_files.clear();
                push
            }
            _ => None,
        }
    }
}

/// Whether a call changes a file: a named editing tool, or any call that carries a diff.
fn edits(call: &AgentToolCall) -> bool {
    const EDITING_TOOLS: [&str; 4] = ["Edit", "Write", "MultiEdit", "NotebookEdit"];
    call.file_path.is_some() && (EDITING_TOOLS.contains(&call.name.as_str()) || call.diff.is_some())
}

fn approval(session_id: &str, approval_id: &str, call: &AgentToolCall, reason: Option<&str>, agent_name: &str) -> AgentPush {
    let body = truncated(&approval_text(call.detail.as_deref(), reason));
    AgentPush {
        title: format!("{agent_name} asks"),
        body: if body.is_empty() { "Needs your approval.".to_owned() } else { body },
        action: Some(PushAction { category: category_for(call), session_id: session_id.to_owned(), approval_id: approval_id.to_owned() }),
    }
}

/// The command is what the person decides on; the reason follows it and says nothing alone.
fn approval_text(command: Option<&str>, reason: Option<&str>) -> String {
    [command, reason].into_iter().flatten().map(str::trim).filter(|part| !part.is_empty()).collect::<Vec<_>>().join("\n\n")
}

/// A push cannot carry per question button titles, so a plain Yes or No question gets fixed buttons and any other question
/// gets Open. One tap on a lock screen must not approve what the banner cut short or never named.
pub fn category_for(call: &AgentToolCall) -> &'static str {
    let questions = call.questions.as_deref().unwrap_or_default();
    if call.name == "ExitPlanMode" || questions.len() > 1 {
        return OPEN_CATEGORY;
    }
    let [question] = questions else {
        return if shows_whole_command(call.detail.as_deref()) { TOOL_CATEGORY } else { OPEN_CATEGORY };
    };
    let labels: Vec<&str> = question.options.iter().map(|option| option.label.as_str()).filter(|label| !label.is_empty()).collect();
    if (1..=MAXIMUM_OPTION_ACTIONS).contains(&labels.len()) && is_yes_no(&labels) {
        YES_NO_CATEGORY
    } else {
        OPEN_CATEGORY
    }
}

fn is_yes_no(labels: &[&str]) -> bool {
    let mut words: Vec<String> = labels.iter().map(|label| label.trim().to_lowercase()).collect();
    words.sort();
    words == ["no", "yes"]
}

fn shows_whole_command(detail: Option<&str>) -> bool {
    detail.map(str::trim).is_some_and(|text| !text.is_empty() && text.chars().count() < MAXIMUM_BODY_CHARACTERS)
}

fn finished_push(session_id: &str, summary: &AgentTurnSummary, turn: &Turn, agent_name: &str) -> AgentPush {
    let (verb, sentence) = if summary.ok {
        ("finished", "The turn finished.")
    } else if summary.stopped {
        ("stopped", "The turn was stopped.")
    } else {
        ("failed", "The turn failed.")
    };
    let headline = turn
        .last_reply
        .as_deref()
        .filter(|reply| !reply.is_empty())
        .map(|reply| reply.lines().next().unwrap_or(reply).chars().take(FIRST_LINE_CHARACTERS).collect::<String>())
        .unwrap_or_else(|| sentence.to_owned());
    let body = match digest(turn.edited_files.len(), summary.duration) {
        Some(detail) => format!("{headline}\n{detail}"),
        None => headline,
    };
    AgentPush {
        title: format!("{agent_name} {verb}"),
        body,
        action: summary.ok.then(|| PushAction { category: FINISHED_CATEGORY, session_id: session_id.to_owned(), approval_id: String::new() }),
    }
}

/// "3 files changed · 2m 14s", or nothing when the turn changed nothing and took no time worth saying.
fn digest(edited_files: usize, duration: Option<f64>) -> Option<String> {
    let mut parts = Vec::new();
    match edited_files {
        0 => {}
        1 => parts.push("1 file changed".to_owned()),
        count => parts.push(format!("{count} files changed")),
    }
    if let Some(seconds) = duration.filter(|seconds| seconds.is_finite() && *seconds >= WORTH_SAYING_SECONDS) {
        parts.push(spoken_duration(seconds));
    }
    (!parts.is_empty()).then(|| parts.join(" \u{b7} "))
}

fn spoken_duration(seconds: f64) -> String {
    if seconds < 60.0 {
        format!("{seconds:.1}s")
    } else {
        let whole = seconds as u64;
        format!("{}m {}s", whole / 60, whole % 60)
    }
}

fn truncated(text: &str) -> String {
    let trimmed = text.trim();
    if trimmed.chars().count() <= MAXIMUM_BODY_CHARACTERS {
        return trimmed.to_owned();
    }
    let cut: String = trimmed.chars().take(MAXIMUM_BODY_CHARACTERS - 1).collect();
    format!("{}\u{2026}", cut.trim())
}

#[cfg(test)]
mod tests;
