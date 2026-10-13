//! One chat turn against a scripted Claude Code process: the prompt goes in, streamed text and a tool ask come out,
//! and the answer is written back as a control response.

mod common;

use common::*;
use peering_agent::claude_adapter::PROGRAM;
use peering_wire::agent::{AgentApprovalDecision, AgentRequest, AgentSessionState, AgentStreamPayload};

#[test]
fn starting_a_chat_launches_the_cli_in_the_chosen_folder() {
    let chat = start_chat();
    let script = locked(&chat.script);
    assert_eq!(script.launches.len(), 1);
    assert_eq!(script.launches[0].program, PROGRAM);
    assert_eq!(script.launches[0].directory, std::env::temp_dir().join("peering-agent-turn-flow"));
}

#[test]
fn a_prompt_is_written_to_the_cli_and_echoed_into_the_transcript() {
    let mut chat = start_chat();
    let events = chat.manager.handle(AgentRequest::Prompt {
        session_id: chat.session_id.clone(),
        text: "Reply with exactly the word: ready".to_owned(),
    });

    assert!(matches!(
        Chat::stream_payloads(&events).as_slice(),
        [AgentStreamPayload::UserPrompt { text }] if text == "Reply with exactly the word: ready"
    ));
    let written = chat.written();
    assert_eq!(written[0]["type"], "user");
    assert_eq!(written[0]["message"]["content"], "Reply with exactly the word: ready");
}

#[test]
fn streamed_text_arrives_in_order_and_the_turn_finishes_with_the_chat_idle() {
    let mut chat = start_chat();
    chat.push_output(&fixture("text_turn.jsonl"));

    let payloads = Chat::stream_payloads(&chat.poll());

    let deltas: Vec<&str> = payloads
        .iter()
        .filter_map(|payload| match payload {
            AgentStreamPayload::TextDelta { text } => Some(text.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(deltas, ["rea", "dy"]);
    assert!(payloads.iter().any(|payload| matches!(payload, AgentStreamPayload::TurnFinished { .. })));
    assert_eq!(chat.info().state, AgentSessionState::Idle);
}

#[test]
fn a_tool_ask_becomes_an_approval_request_and_waits_for_the_mac_user() {
    let mut chat = start_chat();
    chat.push_output(&fixture("approval_request.jsonl"));

    let events = chat.poll();

    let payloads = Chat::stream_payloads(&events);
    assert_eq!(approval_id_of(&payloads).as_deref(), Some(APPROVAL_ID));
    let call = payloads.iter().find_map(|payload| match payload {
        AgentStreamPayload::ApprovalRequested { call, .. } => Some(call.clone()),
        _ => None,
    });
    assert_eq!(call.map(|call| call.name).as_deref(), Some("Bash"));
    assert_eq!(chat.info().state, AgentSessionState::AwaitingApproval);
}

#[test]
fn allowing_the_ask_writes_an_allow_with_the_tool_input_echoed_back() {
    let mut chat = start_chat();
    chat.push_output(&fixture("approval_request.jsonl"));
    chat.poll();

    let events = chat.manager.handle(AgentRequest::Approval {
        session_id: chat.session_id.clone(),
        approval_id: APPROVAL_ID.to_owned(),
        decision: AgentApprovalDecision::Allow {},
    });

    assert!(matches!(
        Chat::stream_payloads(&events).as_slice(),
        [AgentStreamPayload::ApprovalResolved { approval_id, decision: AgentApprovalDecision::Allow {} }]
            if approval_id == APPROVAL_ID
    ));
    let answer = chat.written().pop().expect("an answer was written");
    assert_eq!(answer["type"], "control_response");
    assert_eq!(answer["response"]["subtype"], "success");
    assert_eq!(answer["response"]["request_id"], APPROVAL_ID);
    assert_eq!(answer["response"]["response"]["behavior"], "allow");
    assert_eq!(answer["response"]["response"]["updatedInput"]["command"], "rm -f /tmp/agentchat-capture/nonexistent.txt");
}

#[test]
fn denying_the_ask_writes_a_deny_with_a_reason_the_cli_can_show() {
    let mut chat = start_chat();
    chat.push_output(&[bash_ask("req-deny")]);
    chat.poll();

    chat.manager.handle(AgentRequest::Approval {
        session_id: chat.session_id.clone(),
        approval_id: "req-deny".to_owned(),
        decision: AgentApprovalDecision::Deny {},
    });

    let answer = chat.written().pop().expect("an answer was written");
    assert_eq!(answer["response"]["request_id"], "req-deny");
    assert_eq!(answer["response"]["response"]["behavior"], "deny");
    assert_eq!(answer["response"]["response"]["message"], "Denied from Peering.");
    assert_eq!(chat.info().state, AgentSessionState::Working, "the turn carries on after a deny");
}

#[test]
fn an_answer_to_an_ask_that_is_no_longer_waiting_is_ignored() {
    let mut chat = start_chat();
    chat.push_output(&[bash_ask("req-once")]);
    chat.poll();
    chat.manager.handle(AgentRequest::Approval {
        session_id: chat.session_id.clone(),
        approval_id: "req-once".to_owned(),
        decision: AgentApprovalDecision::Allow {},
    });
    let written_before = chat.written().len();

    let late = chat.manager.handle(AgentRequest::Approval {
        session_id: chat.session_id.clone(),
        approval_id: "req-once".to_owned(),
        decision: AgentApprovalDecision::Deny {},
    });

    assert!(late.is_empty());
    assert_eq!(chat.written().len(), written_before);
}

#[test]
fn interrupting_writes_an_interrupt_control_request() {
    let mut chat = start_chat();
    chat.manager.handle(AgentRequest::Interrupt { session_id: chat.session_id.clone() });

    let request = chat.written().pop().expect("a request was written");
    assert_eq!(request["type"], "control_request");
    assert_eq!(request["request"]["subtype"], "interrupt");
}
