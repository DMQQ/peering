//! One chat turn against a scripted Claude Code process: the prompt goes in, streamed text and a tool ask come out,
//! the answer is written back as a control response, and a reconnecting client replays what it missed.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use peering_agent::claude_adapter::{ChildProcess, LaunchSpec, ProcessLauncher, ReadResult, PROGRAM};
use peering_agent::manager::AgentSessionManager;
use peering_wire::agent::{
    AgentApprovalDecision, AgentEvent, AgentRequest, AgentSessionInfo, AgentSessionState, AgentStreamEvent,
    AgentStreamPayload,
};
use serde_json::{json, Value};

const APPROVAL_ID: &str = "49f17c21-744b-4bc7-a5ee-4ecf7225a13c";

#[derive(Debug, Default)]
struct Script {
    output: std::collections::VecDeque<String>,
    closed: bool,
    written: Vec<String>,
    interrupts: usize,
    launches: Vec<LaunchSpec>,
}

type SharedScript = Arc<Mutex<Script>>;

fn locked(script: &SharedScript) -> MutexGuard<'_, Script> {
    script.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A child process that prints the scripted lines and records what it is sent.
struct ScriptedChild(SharedScript);

impl ChildProcess for ScriptedChild {
    fn write_line(&mut self, line: &str) -> bool {
        locked(&self.0).written.push(line.to_owned());
        true
    }

    fn read_line(&mut self) -> ReadResult {
        let mut script = locked(&self.0);
        match script.output.pop_front() {
            Some(line) => ReadResult::Line(line),
            None if script.closed => ReadResult::Closed,
            None => ReadResult::Pending,
        }
    }

    fn interrupt(&mut self) {
        locked(&self.0).interrupts += 1;
    }

    fn kill(&mut self) {
        locked(&self.0).closed = true;
    }

    fn exit_status(&mut self) -> Option<i32> {
        locked(&self.0).closed.then_some(0)
    }
}

struct ScriptedLauncher(SharedScript);

impl ProcessLauncher for ScriptedLauncher {
    fn spawn(&mut self, command: LaunchSpec) -> Box<dyn ChildProcess> {
        locked(&self.0).launches.push(command);
        Box::new(ScriptedChild(Arc::clone(&self.0)))
    }
}

struct Chat {
    manager: AgentSessionManager<ScriptedLauncher>,
    script: SharedScript,
    session_id: String,
}

fn fixture(name: &str) -> Vec<String> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/claude").join(name);
    std::fs::read_to_string(path)
        .expect("fixture is checked in")
        .lines()
        .map(str::to_owned)
        .collect()
}

fn start_chat() -> Chat {
    let script = SharedScript::default();
    let mut manager = AgentSessionManager::new(ScriptedLauncher(Arc::clone(&script)));
    let directory = std::env::temp_dir().join("peering-agent-turn-flow");
    let events = manager.handle(AgentRequest::Start {
        agent_id: "claude".to_owned(),
        directory: Some(directory.to_string_lossy().into_owned()),
    });
    let [AgentEvent::Created { session }] = events.as_slice() else {
        panic!("expected a created chat, got {events:?}");
    };
    Chat { manager, script, session_id: session.id.clone() }
}

impl Chat {
    fn push_output(&self, lines: &[String]) {
        locked(&self.script).output.extend(lines.iter().cloned());
    }

    fn poll(&mut self) -> Vec<AgentEvent> {
        self.manager.poll()
    }

    fn written(&self) -> Vec<Value> {
        locked(&self.script)
            .written
            .iter()
            .map(|line| serde_json::from_str(line).expect("the CLI is sent JSON lines"))
            .collect()
    }

    fn info(&mut self) -> AgentSessionInfo {
        match self.manager.handle(AgentRequest::List {}).as_slice() {
            [AgentEvent::Snapshot { sessions }] => sessions
                .iter()
                .find(|session| session.id == self.session_id)
                .cloned()
                .expect("the chat is listed"),
            other => panic!("expected a snapshot, got {other:?}"),
        }
    }

    fn stream_payloads(events: &[AgentEvent]) -> Vec<AgentStreamPayload> {
        events
            .iter()
            .filter_map(|event| match event {
                AgentEvent::Stream { event, .. } => Some(event.payload.clone()),
                _ => None,
            })
            .collect()
    }

    fn stream_events(events: &[AgentEvent]) -> Vec<AgentStreamEvent> {
        events
            .iter()
            .filter_map(|event| match event {
                AgentEvent::Stream { event, .. } => Some(event.clone()),
                _ => None,
            })
            .collect()
    }
}

/// A `can_use_tool` ask in the shape the CLI prints, with the request id chosen by the test.
fn bash_ask(request_id: &str) -> String {
    json!({
        "type": "control_request",
        "request_id": request_id,
        "request": {
            "subtype": "can_use_tool",
            "tool_name": "Bash",
            "display_name": "Bash",
            "input": {"command": "rm -f notes.txt", "description": "Remove notes.txt"},
            "description": "Remove notes.txt",
        },
    })
    .to_string()
}

fn approval_id_of(payloads: &[AgentStreamPayload]) -> Option<String> {
    payloads.iter().find_map(|payload| match payload {
        AgentStreamPayload::ApprovalRequested { approval_id, .. } => Some(approval_id.clone()),
        _ => None,
    })
}

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

#[test]
fn a_reconnecting_client_replays_only_the_events_after_the_last_one_it_saw() {
    let mut chat = start_chat();
    chat.manager.handle(AgentRequest::Prompt { session_id: chat.session_id.clone(), text: "ready?".to_owned() });
    chat.push_output(&fixture("text_turn.jsonl"));
    let live = Chat::stream_events(&chat.poll());
    let seen_up_to = live
        .iter()
        .find(|event| matches!(&event.payload, AgentStreamPayload::TextDelta { text } if text == "dy"))
        .expect("the last streamed delta was shown live")
        .index;

    let replay = chat.manager.handle(AgentRequest::History { session_id: chat.session_id.clone(), since: seen_up_to });

    let mut replayed: Vec<AgentStreamEvent> = Vec::new();
    let mut last_flags = Vec::new();
    for event in &replay {
        let AgentEvent::Replay { events, is_last, truncated_at_front, .. } = event else {
            panic!("expected a replay, got {event:?}");
        };
        assert!(!truncated_at_front);
        replayed.extend(events.iter().cloned());
        last_flags.push(*is_last);
    }
    // The final text replaces the deltas that built it, so the replay holds the tail only.
    assert!(matches!(
        replayed.as_slice(),
        [final_text, turn_end]
            if matches!(&final_text.payload, AgentStreamPayload::TextFinal { text } if text == "ready")
                && matches!(turn_end.payload, AgentStreamPayload::TurnFinished { .. })
                && final_text.index > seen_up_to
    ));
    assert_eq!(last_flags.last(), Some(&true));
}

#[test]
fn a_client_that_is_up_to_date_gets_an_empty_final_replay() {
    let mut chat = start_chat();
    chat.push_output(&fixture("text_turn.jsonl"));
    chat.poll();

    let replay = chat.manager.handle(AgentRequest::History { session_id: chat.session_id.clone(), since: u64::MAX - 1 });

    assert!(matches!(
        replay.as_slice(),
        [AgentEvent::Replay { events, is_last: true, .. }] if events.is_empty()
    ));
}
