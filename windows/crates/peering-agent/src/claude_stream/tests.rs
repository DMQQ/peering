//! Turns, approvals and noise. Fixtures are lines captured from a real Claude Code 2.1.289 process, trimmed to the
//! fields the parser reads. Call shapes, sub-agents and usage are in `tests_shapes.rs`.

use super::ClaudeStream;
use peering_wire::agent::{AgentPlanStepStatus, AgentStreamPayload, AgentToolCall};

const TEXT_TURN: &str = include_str!("../../tests/fixtures/claude/text_turn.jsonl");
const TWO_TURNS: &str = include_str!("../../tests/fixtures/claude/two_turns.jsonl");
const TOOL_TURN: &str = include_str!("../../tests/fixtures/claude/tool_turn.jsonl");
const DENIED_TOOL: &str = include_str!("../../tests/fixtures/claude/denied_tool.jsonl");
const APPROVAL_REQUEST: &str = include_str!("../../tests/fixtures/claude/approval_request.jsonl");
const QUESTION_ASK: &str = include_str!("../../tests/fixtures/claude/question_ask.jsonl");
const REPLAYED_PROMPT: &str = include_str!("../../tests/fixtures/claude/replayed_prompt.jsonl");
const AGENT_LAUNCH_RESULT: &str = include_str!("../../tests/fixtures/claude/agent_launch_result.jsonl");

const SESSION_ID: &str = "2398a6db-8e32-4169-b1ca-09bcfdb80e58";
const APPROVAL_ID: &str = "49f17c21-744b-4bc7-a5ee-4ecf7225a13c";

pub(super) fn feed(stream: &mut ClaudeStream, fixture: &str) -> Vec<AgentStreamPayload> {
    fixture.lines().flat_map(|line| stream.feed_line(line)).collect()
}

pub(super) fn feed_one(line: &str) -> Vec<AgentStreamPayload> {
    ClaudeStream::new().feed_line(line)
}

pub(super) fn assert_close(actual: Option<f64>, expected: f64) {
    let actual = actual.expect("a value");
    assert!((actual - expected).abs() < 0.000_001, "{actual} is not {expected}");
}

pub(super) fn tool_call_of(payload: &AgentStreamPayload) -> &AgentToolCall {
    match payload {
        AgentStreamPayload::ToolStarted { call } => call,
        AgentStreamPayload::ApprovalRequested { call, .. } => call,
        other => panic!("expected a tool call, got {other:?}"),
    }
}

#[test]
fn text_turn_streams_deltas_then_final_text_and_summary() {
    let mut stream = ClaudeStream::new();
    let payloads = feed(&mut stream, TEXT_TURN);

    assert_eq!(stream.cli_session_id(), Some(SESSION_ID));
    assert_eq!(payloads.len(), 5);
    assert_eq!(
        payloads[0],
        AgentStreamPayload::SessionReady {
            agent_id: "claude".to_owned(),
            cli_session_id: Some(SESSION_ID.to_owned()),
            model: Some("deepseek-flash[1m]".to_owned()),
            directory: "/private/tmp/agentchat-capture".to_owned(),
        }
    );
    assert_eq!(payloads[1], AgentStreamPayload::TextDelta { text: "rea".to_owned() });
    assert_eq!(payloads[2], AgentStreamPayload::TextDelta { text: "dy".to_owned() });
    assert_eq!(payloads[3], AgentStreamPayload::TextFinal { text: "ready".to_owned() });

    let AgentStreamPayload::TurnFinished { summary } = &payloads[4] else {
        panic!("expected turnFinished last, got {:?}", payloads[4]);
    };
    assert!(summary.ok);
    assert!(!summary.stopped);
    assert_close(summary.cost_usd, 0.196795);
    assert_eq!(summary.input_tokens, Some(39349));
    assert_eq!(summary.output_tokens, Some(2));
    assert_close(summary.duration, 1.641);
    assert_eq!(summary.model.as_deref(), Some("deepseek-flash[1m]"));
}

#[test]
fn cost_is_per_turn_not_the_running_total() {
    let payloads = feed(&mut ClaudeStream::new(), TWO_TURNS);
    let (AgentStreamPayload::TurnFinished { summary: first }, AgentStreamPayload::TurnFinished { summary: second }) =
        (&payloads[1], &payloads[2])
    else {
        panic!("expected two summaries, got {payloads:?}");
    };
    assert_close(first.cost_usd, 0.196795);
    assert_close(second.cost_usd, 0.020744);
    assert_eq!(second.input_tokens, Some(222));
}

#[test]
fn tool_call_and_result_are_matched_by_id() {
    let payloads = feed(&mut ClaudeStream::new(), TOOL_TURN);
    let AgentStreamPayload::ToolStarted { call } = &payloads[0] else {
        panic!("expected toolStarted, got {:?}", payloads[0]);
    };
    assert_eq!(call.id, "call_00_EklvM8Zu3twQyvboNvfy2187");
    assert_eq!(call.name, "Bash");
    assert_eq!(call.title, "Bash");
    assert_eq!(call.detail.as_deref(), Some("echo peering-test"));

    assert_eq!(
        payloads[1],
        AgentStreamPayload::ToolFinished {
            call_id: call.id.clone(),
            ok: true,
            output: Some("peering-test".to_owned()),
            truncated: false,
        }
    );
}

#[test]
fn denied_tool_result_is_not_ok_and_keeps_its_message() {
    let payloads = feed(&mut ClaudeStream::new(), DENIED_TOOL);
    assert_eq!(
        payloads[0],
        AgentStreamPayload::ToolFinished {
            call_id: "call_00_Liez".to_owned(),
            ok: false,
            output: Some("Denied from the capture driver.".to_owned()),
            truncated: false,
        }
    );
}

#[test]
fn approval_request_carries_the_request_id_and_the_tool_use_id() {
    let payloads = feed(&mut ClaudeStream::new(), APPROVAL_REQUEST);
    let AgentStreamPayload::ApprovalRequested {
        approval_id,
        call,
        reason,
    } = &payloads[0]
    else {
        panic!("expected approvalRequested, got {:?}", payloads[0]);
    };
    assert_eq!(approval_id, APPROVAL_ID);
    assert_eq!(call.id, "call_00_Liezk1XgeNgoKbBzb6sI4460");
    assert_eq!(call.name, "Bash");
    assert_eq!(call.title, "Bash");
    assert_eq!(call.detail.as_deref(), Some("rm -f /tmp/agentchat-capture/nonexistent.txt"));
    assert_eq!(reason.as_deref(), Some("Remove nonexistent.txt from /tmp/agentchat-capture"));
}

#[test]
fn approval_input_is_held_for_the_answer_and_taken_once() {
    let mut stream = ClaudeStream::new();
    feed(&mut stream, APPROVAL_REQUEST);
    let input = stream.take_approval_input(APPROVAL_ID).expect("held input");
    assert_eq!(
        input.get("command").and_then(|value| value.as_str()),
        Some("rm -f /tmp/agentchat-capture/nonexistent.txt")
    );
    assert!(stream.take_approval_input(APPROVAL_ID).is_none());
}

#[test]
fn question_ask_carries_the_question_and_its_choices() {
    let mut stream = ClaudeStream::new();
    let payloads = feed(&mut stream, QUESTION_ASK);
    let AgentStreamPayload::ApprovalRequested { approval_id, call, .. } = &payloads[0] else {
        panic!("expected approvalRequested, got {:?}", payloads[0]);
    };
    assert_eq!(approval_id, "82feeba8-70c5-48a1-b269-d515d366a09b");
    assert_eq!(call.name, "AskUserQuestion");
    assert_eq!(call.title, "Colour");
    assert_eq!(call.detail.as_deref(), Some("Which colour do you prefer?"));
    let questions = call.questions.as_ref().expect("questions");
    assert_eq!(questions.len(), 1);
    let labels: Vec<&str> = questions[0].options.iter().map(|option| option.label.as_str()).collect();
    assert_eq!(labels, ["Red", "Blue"]);
    assert_eq!(questions[0].options[0].detail.as_deref(), Some("You prefer red."));
    assert!(stream.take_approval_input(approval_id).is_some());
}

#[test]
fn agent_launch_result_is_not_shown_to_the_user() {
    let payloads = feed(&mut ClaudeStream::new(), AGENT_LAUNCH_RESULT);
    assert_eq!(
        payloads[0],
        AgentStreamPayload::ToolFinished {
            call_id: "t1".to_owned(),
            ok: true,
            output: None,
            truncated: false,
        }
    );
}

#[test]
fn interrupted_result_is_marked_stopped() {
    let line = r#"{"type":"result","subtype":"success","is_error":false,"terminal_reason":"aborted_streaming","num_turns":1,"session_id":"s"}"#;
    let payloads = feed_one(line);
    let AgentStreamPayload::TurnFinished { summary } = &payloads[0] else {
        panic!("expected turnFinished, got {:?}", payloads[0]);
    };
    assert!(summary.stopped);
}

#[test]
fn failed_turn_says_why_before_it_finishes() {
    let line = r#"{"type":"result","subtype":"error","is_error":true,"terminal_reason":"completed","result":"  Context is full.  ","session_id":"s"}"#;
    let payloads = feed_one(line);
    assert_eq!(payloads[0], AgentStreamPayload::Notice { text: "Context is full.".to_owned() });
    let AgentStreamPayload::TurnFinished { summary } = &payloads[1] else {
        panic!("expected turnFinished, got {:?}", payloads[1]);
    };
    assert!(!summary.ok);
}

#[test]
fn noise_is_quiet_and_each_unknown_kind_is_announced_once() {
    let status = r#"{"type":"system","subtype":"status","status":"requesting","session_id":"s"}"#;
    let thinking = r#"{"type":"system","subtype":"thinking_tokens","estimated_tokens":5,"session_id":"s"}"#;
    let unknown = r#"{"type":"something_new","session_id":"s"}"#;
    let mut stream = ClaudeStream::new();

    assert!(stream.feed_line(status).is_empty());
    assert!(stream.feed_line(thinking).is_empty());
    assert_eq!(stream.feed_line(unknown).len(), 1);
    assert!(stream.feed_line(unknown).is_empty());
}

#[test]
fn malformed_lines_are_reported_without_panicking() {
    let mut stream = ClaudeStream::new();
    assert_eq!(stream.feed_line("not json at all").len(), 1);
    assert_eq!(stream.feed_line("[1,2,3]").len(), 1);
    assert_eq!(stream.feed_line(r#"{"subtype":"init"}"#).len(), 1);
    assert_eq!(stream.feed_line("").len(), 1);
}

#[test]
fn unknown_control_request_is_named_by_its_subtype() {
    let line = r#"{"type":"control_request","request_id":"h1","request":{"subtype":"hook_callback"}}"#;
    assert_eq!(
        feed_one(line),
        vec![AgentStreamPayload::Notice {
            text: "Claude Code sent something this app does not know how to show (control_request/hook_callback)."
                .to_owned(),
        }]
    );
}

#[test]
fn replayed_prompt_and_control_responses_are_quiet() {
    let mut stream = ClaudeStream::new();
    assert!(feed(&mut stream, REPLAYED_PROMPT).is_empty());
    let receipt = r#"{"type":"control_response","response":{"subtype":"success","request_id":"req_1","response":{"still_queued":[],"cancelled":[]}}}"#;
    assert!(stream.feed_line(receipt).is_empty());
}

#[test]
fn todo_write_becomes_a_plan_card_with_each_step_status() {
    let todo = r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t9","name":"TodoWrite","input":{"todos":[{"content":"Read the file","status":"completed"},{"content":"Write the test","status":"in_progress"},{"content":"Ship it","status":"pending"}]}}]},"parent_tool_use_id":null,"session_id":"s"}"#;
    let payloads = feed_one(todo);
    let call = tool_call_of(&payloads[0]);
    assert_eq!(call.title, "Plan");
    let steps = call.plan.as_ref().expect("plan");
    let texts: Vec<&str> = steps.iter().map(|step| step.text.as_str()).collect();
    assert_eq!(texts, ["Read the file", "Write the test", "Ship it"]);
    let statuses: Vec<AgentPlanStepStatus> = steps.iter().map(|step| step.status).collect();
    assert_eq!(
        statuses,
        [AgentPlanStepStatus::Completed, AgentPlanStepStatus::InProgress, AgentPlanStepStatus::Pending]
    );
    assert!(call.questions.is_none());
}
