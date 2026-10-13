//! Starting, prompting, reading a turn, and the process ending. Control requests and approvals are in
//! `tests_control.rs`.

use super::fake::{lock, push_lines, shared_script, ScriptedLauncher, SharedScript};
use super::{ClaudeAdapter, ClaudeResume};
use peering_wire::agent::{AgentPermissionMode, AgentStreamPayload};
use serde_json::{json, Value};
use std::path::PathBuf;

const TEXT_TURN: &str = include_str!("../../tests/fixtures/claude/text_turn.jsonl");
const SESSION_ID: &str = "2398a6db-8e32-4169-b1ca-09bcfdb80e58";
const BASE_ARGUMENTS: [&str; 10] = [
    "-p",
    "--input-format",
    "stream-json",
    "--output-format",
    "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--replay-user-messages",
    "--permission-prompt-tool",
    "stdio",
];

pub(super) fn started_with(resume: ClaudeResume) -> (ClaudeAdapter, SharedScript) {
    let script = shared_script();
    let mut adapter = ClaudeAdapter::new(PathBuf::from("/work/project"), resume);
    adapter.start(&mut ScriptedLauncher::new(&script));
    (adapter, script)
}

pub(super) fn written(script: &SharedScript) -> Vec<Value> {
    lock(script)
        .written
        .iter()
        .map(|line| serde_json::from_str(line).expect("the adapter writes JSON"))
        .collect()
}

fn argument_list(script: &SharedScript) -> Vec<String> {
    lock(script).launches[0].arguments.clone()
}

#[test]
fn the_cli_starts_with_the_stream_json_flags_in_its_directory() {
    let (_, script) = started_with(ClaudeResume::default());
    let launch = lock(&script).launches[0].clone();
    assert_eq!(launch.program, "claude");
    assert_eq!(launch.directory, PathBuf::from("/work/project"));
    assert_eq!(launch.arguments, BASE_ARGUMENTS);
}

#[test]
fn a_resumed_session_adds_its_id_model_and_non_manual_mode() {
    let resume = ClaudeResume {
        cli_session_id: Some(SESSION_ID.to_owned()),
        model: Some("sonnet".to_owned()),
        permission_mode: Some(AgentPermissionMode::Plan),
    };
    let (_, script) = started_with(resume);
    let expected: Vec<&str> = BASE_ARGUMENTS
        .iter()
        .copied()
        .chain(["--resume", SESSION_ID, "--model", "sonnet", "--permission-mode", "plan"])
        .collect();
    assert_eq!(argument_list(&script), expected);
}

#[test]
fn manual_mode_is_the_cli_default_and_is_not_passed() {
    let resume = ClaudeResume {
        permission_mode: Some(AgentPermissionMode::Manual),
        ..ClaudeResume::default()
    };
    let (_, script) = started_with(resume);
    assert_eq!(argument_list(&script), BASE_ARGUMENTS);
}

#[test]
fn a_prompt_is_written_as_a_stream_json_user_message() {
    let (mut adapter, script) = started_with(ClaudeResume::default());
    assert!(adapter.prompt("Reply with exactly the word: ready"));
    assert_eq!(
        written(&script),
        [json!({
            "type": "user",
            "message": {"role": "user", "content": "Reply with exactly the word: ready"},
            "parent_tool_use_id": null,
        })]
    );
}

#[test]
fn a_streamed_turn_comes_back_through_poll_in_order() {
    let (mut adapter, script) = started_with(ClaudeResume::default());
    push_lines(&script, &TEXT_TURN.lines().collect::<Vec<_>>());

    let payloads = adapter.poll();
    assert_eq!(payloads.len(), 5);
    assert!(matches!(payloads[0], AgentStreamPayload::SessionReady { .. }));
    assert_eq!(payloads[3], AgentStreamPayload::TextFinal { text: "ready".to_owned() });
    assert!(matches!(payloads[4], AgentStreamPayload::TurnFinished { .. }));
    assert_eq!(adapter.cli_session_id(), Some(SESSION_ID));
    assert_eq!(adapter.model(), Some("deepseek-flash[1m]"));
    assert!(adapter.poll().is_empty());
}

#[test]
fn a_process_that_ends_before_saying_anything_reports_a_failure_then_its_exit() {
    let (mut adapter, script) = started_with(ClaudeResume::default());
    {
        let mut script = lock(&script);
        script.closed = true;
        script.exit_status = 1;
    }
    assert_eq!(
        adapter.poll(),
        [
            AgentStreamPayload::Failure {
                message: "Claude Code started and stopped before saying anything. Update it, or use the terminal instead."
                    .to_owned(),
            },
            AgentStreamPayload::SessionExited { status: 1 },
        ]
    );
    assert!(!adapter.is_running());
    assert!(adapter.poll().is_empty());
}

#[test]
fn a_clean_exit_after_a_turn_is_not_reported_as_a_failure() {
    let (mut adapter, script) = started_with(ClaudeResume::default());
    push_lines(&script, &TEXT_TURN.lines().collect::<Vec<_>>());
    lock(&script).closed = true;

    let payloads = adapter.poll();
    assert!(!payloads.iter().any(|payload| matches!(payload, AgentStreamPayload::Failure { .. })));
    assert_eq!(payloads.last(), Some(&AgentStreamPayload::SessionExited { status: 0 }));
}

#[test]
fn a_nonzero_exit_after_the_session_is_ready_names_the_status() {
    let (mut adapter, script) = started_with(ClaudeResume::default());
    push_lines(&script, &TEXT_TURN.lines().take(1).collect::<Vec<_>>());
    {
        let mut script = lock(&script);
        script.closed = true;
        script.exit_status = 2;
    }
    let payloads = adapter.poll();
    assert_eq!(
        &payloads[1..],
        [
            AgentStreamPayload::Failure {
                message: "Claude Code exited with status 2.".to_owned(),
            },
            AgentStreamPayload::SessionExited { status: 2 },
        ]
    );
}

#[test]
fn a_prompt_the_process_refuses_is_reported_as_not_sent() {
    let (mut adapter, script) = started_with(ClaudeResume::default());
    lock(&script).refuse_input = true;
    assert!(!adapter.prompt("hello"));
    assert!(written(&script).is_empty());
}

#[test]
fn stop_kills_the_process_and_nothing_is_sent_after_it() {
    let (mut adapter, script) = started_with(ClaudeResume::default());
    adapter.stop();
    assert!(lock(&script).killed);
    assert!(!adapter.is_running());
    assert!(!adapter.prompt("too late"));
}
