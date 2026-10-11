//! Approvals, model and mode changes, and interrupts: what the adapter writes, and how the CLI's answers land.

use super::fake::push_lines;
use super::tests::{started_with, written};
use super::ClaudeResume;
use peering_wire::agent::{AgentApprovalDecision, AgentPermissionMode, AgentStreamPayload};
use serde_json::{json, Value};

const APPROVAL_REQUEST: &str = include_str!("../../tests/fixtures/claude/approval_request.jsonl");
const QUESTION_ASK: &str = include_str!("../../tests/fixtures/claude/question_ask.jsonl");
const APPROVAL_ID: &str = "49f17c21-744b-4bc7-a5ee-4ecf7225a13c";
const PLAN_ASK: &str = r#"{"type":"control_request","request_id":"plan-ask","request":{"subtype":"can_use_tool","tool_name":"ExitPlanMode","input":{"plan":"Step one"},"tool_use_id":"toolu_plan"}}"#;

fn control_response(request_id: &str, body: Value) -> String {
    json!({"type": "control_response", "response": {"subtype": "success", "request_id": request_id, "response": body}})
        .to_string()
}

fn control_error(request_id: &str, error: &str) -> String {
    json!({"type": "control_response", "response": {"subtype": "error", "request_id": request_id, "error": error}})
        .to_string()
}

fn body_of(answer: &Value) -> &Value {
    &answer["response"]["response"]
}

#[test]
fn allow_echoes_the_tool_input_back_to_the_cli() {
    let (mut adapter, script) = started_with(ClaudeResume::default());
    push_lines(&script, &[APPROVAL_REQUEST]);
    assert!(matches!(adapter.poll()[0], AgentStreamPayload::ApprovalRequested { .. }));

    assert!(adapter.respond(APPROVAL_ID, &AgentApprovalDecision::Allow {}));
    let answer = written(&script).pop().expect("an answer");
    assert_eq!(answer["type"], "control_response");
    assert_eq!(answer["response"]["subtype"], "success");
    assert_eq!(answer["response"]["request_id"], APPROVAL_ID);
    assert_eq!(body_of(&answer)["behavior"], "allow");
    assert_eq!(
        body_of(&answer)["updatedInput"]["command"],
        "rm -f /tmp/agentchat-capture/nonexistent.txt"
    );
}

#[test]
fn deny_says_it_was_denied_from_peering() {
    let (mut adapter, script) = started_with(ClaudeResume::default());
    push_lines(&script, &[APPROVAL_REQUEST]);
    adapter.poll();

    assert!(adapter.respond(APPROVAL_ID, &AgentApprovalDecision::Deny {}));
    let answer = written(&script).pop().expect("an answer");
    assert_eq!(
        body_of(&answer),
        &json!({"behavior": "deny", "message": "Denied from Peering."})
    );
}

#[test]
fn choose_answers_each_question_by_its_text() {
    let (mut adapter, script) = started_with(ClaudeResume::default());
    push_lines(&script, &[QUESTION_ASK]);
    adapter.poll();

    let decision = AgentApprovalDecision::Choose {
        answers: vec!["Blue".to_owned()],
    };
    assert!(adapter.respond("82feeba8-70c5-48a1-b269-d515d366a09b", &decision));
    let answer = written(&script).pop().expect("an answer");
    let updated = &body_of(&answer)["updatedInput"];
    assert_eq!(body_of(&answer)["behavior"], "allow");
    assert_eq!(updated["answers"]["Which colour do you prefer?"], "Blue");
    assert!(updated["questions"].is_array());
}

#[test]
fn approving_a_plan_returns_to_the_mode_before_plan() {
    let (mut adapter, script) = started_with(ClaudeResume::default());
    assert!(adapter.set_permission_mode(AgentPermissionMode::Plan));
    push_lines(&script, &[&control_response("peering-1", json!({}))]);
    adapter.poll();
    assert_eq!(adapter.permission_mode(), AgentPermissionMode::Plan);

    push_lines(&script, &[PLAN_ASK]);
    assert!(matches!(adapter.poll()[0], AgentStreamPayload::ApprovalRequested { .. }));
    assert!(adapter.respond("plan-ask", &AgentApprovalDecision::Allow {}));

    let restore = written(&script).pop().expect("a mode request");
    assert_eq!(restore["request"]["subtype"], "set_permission_mode");
    assert_eq!(restore["request"]["mode"], "default");
    push_lines(&script, &[&control_response("peering-2", json!({}))]);
    adapter.poll();
    assert_eq!(adapter.permission_mode(), AgentPermissionMode::Manual);
}

#[test]
fn set_model_takes_the_model_the_cli_resolved() {
    let (mut adapter, script) = started_with(ClaudeResume::default());
    assert!(adapter.set_model(Some("sonnet")));
    let request = written(&script).pop().expect("a request");
    assert_eq!(request["type"], "control_request");
    assert_eq!(request["request_id"], "peering-1");
    assert_eq!(request["request"]["subtype"], "set_model");
    assert_eq!(request["request"]["model"], "sonnet");

    push_lines(&script, &[&control_response("peering-1", json!({"model": "claude-sonnet-4-5"}))]);
    assert!(adapter.poll().is_empty());
    assert_eq!(adapter.model(), Some("claude-sonnet-4-5"));
}

#[test]
fn set_model_to_the_default_sends_no_model_field() {
    let resume = ClaudeResume {
        model: Some("opus".to_owned()),
        ..ClaudeResume::default()
    };
    let (mut adapter, script) = started_with(resume);
    assert!(adapter.set_model(None));
    let request = written(&script).pop().expect("a request");
    assert!(request["request"].get("model").is_none());

    push_lines(&script, &[&control_response("peering-1", json!({}))]);
    adapter.poll();
    assert_eq!(adapter.model(), None);
}

#[test]
fn a_rejected_model_is_a_notice_and_leaves_the_model_alone() {
    let resume = ClaudeResume {
        model: Some("opus".to_owned()),
        ..ClaudeResume::default()
    };
    let (mut adapter, script) = started_with(resume);
    adapter.set_model(Some("nope"));
    push_lines(&script, &[&control_error("peering-1", "unknown model")]);

    assert_eq!(
        adapter.poll(),
        [AgentStreamPayload::Notice {
            text: "unknown model".to_owned(),
        }]
    );
    assert_eq!(adapter.model(), Some("opus"));
}

#[test]
fn a_rejected_mode_without_a_reason_says_it_was_not_accepted() {
    let (mut adapter, script) = started_with(ClaudeResume::default());
    adapter.set_permission_mode(AgentPermissionMode::Auto);
    push_lines(
        &script,
        &[r#"{"type":"control_response","response":{"subtype":"error","request_id":"peering-1"}}"#],
    );

    assert_eq!(
        adapter.poll(),
        [AgentStreamPayload::Notice {
            text: "That mode was not accepted.".to_owned(),
        }]
    );
    assert_eq!(adapter.permission_mode(), AgentPermissionMode::Manual);
}

#[test]
fn interrupt_is_a_control_request_and_its_receipt_stays_out_of_the_transcript() {
    let (mut adapter, script) = started_with(ClaudeResume::default());
    assert!(adapter.interrupt());
    let request = written(&script).pop().expect("a request");
    assert_eq!(request["type"], "control_request");
    assert_eq!(request["request"]["subtype"], "interrupt");

    push_lines(&script, &[&control_response("peering-1", json!({"still_queued": [], "cancelled": []}))]);
    assert!(adapter.poll().is_empty());
}

#[test]
fn an_approval_answer_after_the_process_ended_is_not_sent() {
    let (mut adapter, script) = started_with(ClaudeResume::default());
    push_lines(&script, &[APPROVAL_REQUEST]);
    adapter.poll();
    adapter.stop();
    assert!(!adapter.respond(APPROVAL_ID, &AgentApprovalDecision::Allow {}));
}
