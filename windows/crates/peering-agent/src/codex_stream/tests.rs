use super::CodexStream;
use peering_wire::agent::{AgentPlanStepStatus, AgentStreamPayload};

fn stream() -> CodexStream {
    CodexStream::new("/work", None)
}

#[test]
fn thread_started_names_the_cli_session_and_the_spawn_folder() {
    let mut stream = stream();
    let payloads = stream.feed_line(r#"{"type":"thread.started","thread_id":"t-1"}"#);
    assert_eq!(
        payloads,
        vec![AgentStreamPayload::SessionReady {
            agent_id: "codex".to_owned(),
            cli_session_id: Some("t-1".to_owned()),
            model: None,
            directory: "/work".to_owned(),
        }]
    );
    assert_eq!(stream.cli_session_id(), Some("t-1"));
}

#[test]
fn a_command_becomes_a_tool_card_that_fails_on_a_nonzero_exit() {
    let mut stream = stream();
    let started = stream.feed_line(
        r#"{"type":"item.started","item":{"id":"c1","type":"command_execution","command":"ls"}}"#,
    );
    let [AgentStreamPayload::ToolStarted { call }] = started.as_slice() else { panic!("{started:?}") };
    assert_eq!((call.title.as_str(), call.detail.as_deref()), ("Command", Some("ls")));
    let done = stream.feed_line(
        r#"{"type":"item.completed","item":{"id":"c1","type":"command_execution","status":"completed","exit_code":2,"aggregated_output":"nope"}}"#,
    );
    assert_eq!(
        done,
        vec![AgentStreamPayload::ToolFinished {
            call_id: "c1".to_owned(),
            ok: false,
            output: Some("nope".to_owned()),
            truncated: false
        }]
    );
}

#[test]
fn turn_completed_reports_tokens_and_keeps_cached_input_apart() {
    let mut stream = stream();
    let payloads = stream.feed_line(
        r#"{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":7}}"#,
    );
    let [AgentStreamPayload::TurnFinished { summary }] = payloads.as_slice() else { panic!("{payloads:?}") };
    assert!(summary.ok);
    assert_eq!((summary.input_tokens, summary.output_tokens), (Some(100), Some(7)));
    assert_eq!((stream.usage().input_tokens, stream.usage().cached_tokens), (60, 40));
}

#[test]
fn a_repeated_error_is_told_once_and_a_nested_message_is_unwrapped() {
    let mut stream = stream();
    let first = stream.feed_line(r#"{"type":"error","message":"{\"error\":{\"message\":\"quota\"}}"}"#);
    assert_eq!(first, vec![AgentStreamPayload::Notice { text: "quota".to_owned() }]);
    let failed = stream.feed_line(r#"{"type":"turn.failed","error":{"message":"{\"error\":{\"message\":\"quota\"}}"}}"#);
    assert_eq!(failed.len(), 1);
    assert!(matches!(&failed[0], AgentStreamPayload::TurnFinished { summary } if !summary.ok));
}

#[test]
fn a_todo_list_carries_its_plan() {
    let mut stream = stream();
    let payloads = stream.feed_line(
        r#"{"type":"item.started","item":{"id":"p","type":"todo_list","items":[{"text":"a","completed":true},{"text":"b"}]}}"#,
    );
    let [AgentStreamPayload::ToolStarted { call }] = payloads.as_slice() else { panic!("{payloads:?}") };
    let plan = call.plan.as_ref().expect("a plan");
    assert_eq!(plan[0].status, AgentPlanStepStatus::Completed);
    assert_eq!(plan[1].status, AgentPlanStepStatus::Pending);
    assert_eq!(call.detail.as_deref(), Some("a; b"));
}

#[test]
fn an_unknown_item_is_announced_once_and_garbage_is_a_notice() {
    let mut stream = stream();
    let line = r#"{"type":"item.started","item":{"id":"x","type":"hologram"}}"#;
    assert_eq!(stream.feed_line(line).len(), 1);
    assert!(stream.feed_line(line).is_empty());
    assert!(matches!(stream.feed_line("not json").as_slice(), [AgentStreamPayload::Notice { .. }]));
}
