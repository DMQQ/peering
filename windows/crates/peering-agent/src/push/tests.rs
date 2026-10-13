use peering_wire::agent::{AgentQuestion, AgentToolOption};

use super::*;

const AWAY: Reach = Reach { has_token: true, foreground: false };
const WATCHING: Reach = Reach { has_token: true, foreground: true };
const NO_TOKEN: Reach = Reach { has_token: false, foreground: false };

fn call(name: &str, detail: Option<&str>) -> AgentToolCall {
    AgentToolCall {
        id: "c1".to_owned(),
        name: name.to_owned(),
        title: name.to_owned(),
        detail: detail.map(str::to_owned),
        file_path: None,
        diff: None,
        questions: None,
        plan: None,
    }
}

fn question(labels: &[&str]) -> AgentQuestion {
    AgentQuestion {
        header: None,
        question: "Proceed?".to_owned(),
        options: labels.iter().map(|label| AgentToolOption { label: (*label).to_owned(), detail: None }).collect(),
    }
}

fn asked(call: AgentToolCall, reason: Option<&str>) -> AgentStreamPayload {
    AgentStreamPayload::ApprovalRequested { approval_id: "a1".to_owned(), call, reason: reason.map(str::to_owned) }
}

fn finished(ok: bool, stopped: bool, duration: Option<f64>) -> AgentStreamPayload {
    AgentStreamPayload::TurnFinished {
        summary: AgentTurnSummary { ok, stopped, cost_usd: None, input_tokens: None, output_tokens: None, duration, model: None },
    }
}

fn edit(path: &str) -> AgentStreamPayload {
    AgentStreamPayload::ToolStarted { call: AgentToolCall { file_path: Some(path.to_owned()), ..call("Edit", None) } }
}

#[test]
fn an_approval_pushes_even_to_a_phone_in_the_foreground() {
    let mut planner = AgentPushPlanner::default();
    let push = planner.observe("s1", &asked(call("Bash", Some("cargo test")), None), "Claude Code", WATCHING).expect("a push");
    assert_eq!(push.title, "Claude Code asks");
    assert_eq!(push.body, "cargo test");
    assert_eq!(push.action, Some(PushAction { category: TOOL_CATEGORY, session_id: "s1".to_owned(), approval_id: "a1".to_owned() }));
}

#[test]
fn without_a_token_nothing_is_pushed() {
    let mut planner = AgentPushPlanner::default();
    assert_eq!(planner.observe("s1", &asked(call("Bash", Some("ls")), None), "Claude Code", NO_TOKEN), None);
    assert_eq!(planner.observe("s1", &finished(true, false, None), "Claude Code", NO_TOKEN), None);
}

#[test]
fn the_reason_follows_the_command_in_the_body() {
    let mut planner = AgentPushPlanner::default();
    let push = planner.observe("s1", &asked(call("Bash", Some("rm -rf build")), Some("Contains a glob")), "Claude Code", AWAY).expect("a push");
    assert_eq!(push.body, "rm -rf build\n\nContains a glob");
}

#[test]
fn an_approval_with_nothing_to_say_still_says_it_needs_you() {
    let mut planner = AgentPushPlanner::default();
    let push = planner.observe("s1", &asked(call("Bash", None), None), "Claude Code", AWAY).expect("a push");
    assert_eq!(push.body, "Needs your approval.");
    assert_eq!(push.action.expect("an action").category, OPEN_CATEGORY, "a request that names nothing opens the app");
}

#[test]
fn a_long_command_is_cut_and_opens_the_app_instead_of_offering_allow() {
    let mut planner = AgentPushPlanner::default();
    let long = "x".repeat(300);
    let push = planner.observe("s1", &asked(call("Bash", Some(&long)), None), "Claude Code", AWAY).expect("a push");
    assert_eq!(push.body.chars().count(), 240);
    assert!(push.body.ends_with('\u{2026}'));
    assert_eq!(push.action.expect("an action").category, OPEN_CATEGORY);
}

#[test]
fn a_yes_or_no_question_gets_the_yes_no_buttons() {
    let with = |labels: &[&str]| AgentToolCall { questions: Some(vec![question(labels)]), ..call("AskUserQuestion", None) };
    assert_eq!(category_for(&with(&["Yes", "No"])), YES_NO_CATEGORY);
    assert_eq!(category_for(&with(&[" no ", "YES"])), YES_NO_CATEGORY);
    assert_eq!(category_for(&with(&["Red", "Green"])), OPEN_CATEGORY);
    assert_eq!(category_for(&with(&["Yes", "No", "Maybe"])), OPEN_CATEGORY);
}

#[test]
fn several_questions_and_plans_open_the_app() {
    let two = AgentToolCall { questions: Some(vec![question(&["Yes", "No"]), question(&["Yes", "No"])]), ..call("AskUserQuestion", None) };
    assert_eq!(category_for(&two), OPEN_CATEGORY);
    assert_eq!(category_for(&call("ExitPlanMode", Some("a plan"))), OPEN_CATEGORY);
}

#[test]
fn a_finished_turn_pushes_only_to_a_phone_that_is_not_watching() {
    let mut planner = AgentPushPlanner::default();
    assert_eq!(planner.observe("s1", &finished(true, false, None), "Claude Code", WATCHING), None);
    assert!(planner.observe("s1", &finished(true, false, None), "Claude Code", AWAY).is_some());
}

#[test]
fn a_finished_turn_uses_the_first_line_of_the_last_reply_and_a_digest() {
    let mut planner = AgentPushPlanner::default();
    planner.observe("s1", &AgentStreamPayload::TurnStarted {}, "Claude Code", AWAY);
    planner.observe("s1", &edit("a.rs"), "Claude Code", AWAY);
    planner.observe("s1", &edit("b.rs"), "Claude Code", AWAY);
    planner.observe("s1", &edit("a.rs"), "Claude Code", AWAY);
    planner.observe("s1", &AgentStreamPayload::TextFinal { text: "Done.\nSecond line".to_owned() }, "Claude Code", AWAY);
    let push = planner.observe("s1", &finished(true, false, Some(134.2)), "Claude Code", AWAY).expect("a push");
    assert_eq!(push.title, "Claude Code finished");
    assert_eq!(push.body, "Done.\n2 files changed \u{b7} 2m 14s");
    assert_eq!(push.action, Some(PushAction { category: FINISHED_CATEGORY, session_id: "s1".to_owned(), approval_id: String::new() }));
}

#[test]
fn a_turn_with_no_reply_says_how_it_ended() {
    let mut planner = AgentPushPlanner::default();
    let push = planner.observe("s1", &finished(true, false, None), "Claude Code", AWAY).expect("a push");
    assert_eq!(push.body, "The turn finished.");
}

#[test]
fn a_stopped_or_failed_turn_offers_no_continue_button() {
    let mut planner = AgentPushPlanner::default();
    let stopped = planner.observe("s1", &finished(false, true, None), "Claude Code", AWAY).expect("a push");
    assert_eq!((stopped.title.as_str(), stopped.body.as_str(), stopped.action), ("Claude Code stopped", "The turn was stopped.", None));
    let failed = planner.observe("s1", &finished(false, false, None), "Claude Code", AWAY).expect("a push");
    assert_eq!((failed.title.as_str(), failed.action), ("Claude Code failed", None));
}

#[test]
fn a_short_turn_does_not_say_how_long_it_took() {
    let mut planner = AgentPushPlanner::default();
    planner.observe("s1", &AgentStreamPayload::TextFinal { text: "ok".to_owned() }, "Claude Code", AWAY);
    let push = planner.observe("s1", &finished(true, false, Some(4.9)), "Claude Code", AWAY).expect("a push");
    assert_eq!(push.body, "ok");
    let slower = planner.observe("s1", &finished(true, false, Some(7.25)), "Claude Code", AWAY).expect("a push");
    assert_eq!(slower.body, "ok\n7.2s");
}

#[test]
fn one_file_is_said_in_the_singular() {
    let mut planner = AgentPushPlanner::default();
    planner.observe("s1", &edit("a.rs"), "Claude Code", AWAY);
    let push = planner.observe("s1", &finished(true, false, None), "Claude Code", AWAY).expect("a push");
    assert!(push.body.ends_with("1 file changed"));
}

#[test]
fn the_files_of_one_turn_do_not_carry_into_the_next() {
    let mut planner = AgentPushPlanner::default();
    planner.observe("s1", &edit("a.rs"), "Claude Code", AWAY);
    planner.observe("s1", &finished(true, false, None), "Claude Code", AWAY);
    let next = planner.observe("s1", &finished(true, false, None), "Claude Code", AWAY).expect("a push");
    assert!(!next.body.contains("changed"));
}

#[test]
fn a_call_that_only_reads_a_file_is_not_an_edit() {
    let reading = AgentToolCall { file_path: Some("a.rs".to_owned()), ..call("Read", None) };
    assert!(!edits(&reading));
    let with_diff = AgentToolCall { diff: Some("@@".to_owned()), ..reading };
    assert!(edits(&with_diff), "any call that carries a diff changed something");
}

#[test]
fn chats_are_kept_apart() {
    let mut planner = AgentPushPlanner::default();
    planner.observe("one", &AgentStreamPayload::TextFinal { text: "first".to_owned() }, "Claude Code", AWAY);
    let other = planner.observe("two", &finished(true, false, None), "Claude Code", AWAY).expect("a push");
    assert_eq!(other.body, "The turn finished.");
}
