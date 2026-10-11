//! Requests and polls through the manager, against a scripted Claude process.

use super::{agent_chat_agents, AgentSessionManager};
use crate::claude_adapter::fake::{lock, push_lines, shared_script, ScriptedLauncher, SharedScript};
use peering_wire::agent::{
    AgentApprovalDecision, AgentEvent, AgentPermissionMode, AgentRequest, AgentSessionInfo, AgentSessionState,
    AgentStreamPayload,
};
use serde_json::{json, Value};
use std::path::PathBuf;

const TEXT_TURN: &str = include_str!("../../tests/fixtures/claude/text_turn.jsonl");
const APPROVAL_REQUEST: &str = include_str!("../../tests/fixtures/claude/approval_request.jsonl");
const APPROVAL_ID: &str = "49f17c21-744b-4bc7-a5ee-4ecf7225a13c";
const PAUSE_NOTICE: &str = "Stopped and moved to history. Send a message to pick this chat up where it left off.";

fn manager() -> (AgentSessionManager<ScriptedLauncher>, SharedScript) {
    let script = shared_script();
    (AgentSessionManager::new(ScriptedLauncher::new(&script)), script)
}

fn start(manager: &mut AgentSessionManager<ScriptedLauncher>, directory: &str) -> String {
    let events = manager.handle(AgentRequest::Start {
        agent_id: "claude".to_owned(),
        directory: Some(directory.to_owned()),
    });
    let [AgentEvent::Created { session }] = events.as_slice() else {
        panic!("expected created, got {events:?}");
    };
    session.id.clone()
}

fn snapshot(manager: &mut AgentSessionManager<ScriptedLauncher>) -> Vec<AgentSessionInfo> {
    match manager.handle(AgentRequest::List {}).as_slice() {
        [AgentEvent::Snapshot { sessions }] => sessions.clone(),
        other => panic!("expected a snapshot, got {other:?}"),
    }
}

fn state_of(manager: &mut AgentSessionManager<ScriptedLauncher>, id: &str) -> AgentSessionState {
    snapshot(manager)
        .into_iter()
        .find(|session| session.id == id)
        .expect("the chat is listed")
        .state
}

fn streamed(events: &[AgentEvent]) -> Vec<AgentStreamPayload> {
    events
        .iter()
        .filter_map(|event| match event {
            AgentEvent::Stream { event, .. } => Some(event.payload.clone()),
            _ => None,
        })
        .collect()
}

fn written(script: &SharedScript) -> Vec<Value> {
    lock(script)
        .written
        .iter()
        .map(|line| serde_json::from_str(line).expect("JSON"))
        .collect()
}

fn prompt(manager: &mut AgentSessionManager<ScriptedLauncher>, id: &str, text: &str) -> Vec<AgentEvent> {
    manager.handle(AgentRequest::Prompt {
        session_id: id.to_owned(),
        text: text.to_owned(),
    })
}

#[test]
fn start_creates_a_chat_and_launches_claude_in_its_folder() {
    let (mut manager, script) = manager();
    let events = manager.handle(AgentRequest::Start {
        agent_id: "claude".to_owned(),
        directory: Some("/work/project".to_owned()),
    });
    let [AgentEvent::Created { session }] = events.as_slice() else {
        panic!("expected created, got {events:?}");
    };
    assert_eq!(session.agent_id, "claude");
    assert_eq!(session.title, "Claude Code · project");
    assert_eq!(session.state, AgentSessionState::Idle);
    assert_eq!(session.last_index, 0);
    assert_eq!(session.directory, "/work/project");
    assert_eq!(lock(&script).launches[0].directory, PathBuf::from("/work/project"));
    assert_eq!(snapshot(&mut manager).len(), 1);
}

#[test]
fn chats_in_the_same_folder_get_numbered_titles() {
    let (mut manager, _) = manager();
    start(&mut manager, "/work/project");
    start(&mut manager, "/work/project");
    let titles: Vec<String> = snapshot(&mut manager).into_iter().map(|session| session.title).collect();
    assert_eq!(titles, ["Claude Code · project", "Claude Code · project 2"]);
}

#[test]
fn an_agent_other_than_claude_fails_with_a_clear_message() {
    let (mut manager, _) = manager();
    let events = manager.handle(AgentRequest::Start {
        agent_id: "codex".to_owned(),
        directory: Some("/work/project".to_owned()),
    });
    assert_eq!(
        events,
        [AgentEvent::Failed {
            session_id: None,
            message: "codex is not supported on this host yet.".to_owned(),
        }]
    );
    assert_eq!(agent_chat_agents(), ["claude"]);
}

#[test]
fn a_chat_needs_an_absolute_folder() {
    let (mut manager, _) = manager();
    let relative = manager.handle(AgentRequest::Start {
        agent_id: "claude".to_owned(),
        directory: Some("project".to_owned()),
    });
    let missing = manager.handle(AgentRequest::Start {
        agent_id: "claude".to_owned(),
        directory: None,
    });
    assert!(matches!(&relative[..], [AgentEvent::Failed { message, .. }] if message == "That is not a folder this host can open."));
    assert!(matches!(&missing[..], [AgentEvent::Failed { message, .. }] if message == "Choose a folder to start the chat in."));
}

#[test]
fn a_prompt_is_logged_then_the_streamed_turn_follows_with_its_facts() {
    let (mut manager, script) = manager();
    let id = start(&mut manager, "/work/project");

    let sent = prompt(&mut manager, &id, "Reply with exactly the word: ready");
    assert_eq!(
        streamed(&sent),
        [AgentStreamPayload::UserPrompt {
            text: "Reply with exactly the word: ready".to_owned(),
        }]
    );
    assert_eq!(written(&script)[0]["message"]["content"], "Reply with exactly the word: ready");

    push_lines(&script, &TEXT_TURN.lines().collect::<Vec<_>>());
    let events = manager.poll();
    assert_eq!(streamed(&events).len(), 5);
    assert!(events.contains(&AgentEvent::ModelChanged {
        session_id: id.clone(),
        model: Some("deepseek-flash[1m]".to_owned()),
    }));
    assert!(events.iter().any(|event| matches!(event, AgentEvent::UsageChanged { .. })));
    assert_eq!(state_of(&mut manager, &id), AgentSessionState::Idle);
}

#[test]
fn history_after_a_turn_skips_the_deltas_the_final_text_replaced() {
    let (mut manager, script) = manager();
    let id = start(&mut manager, "/work/project");
    prompt(&mut manager, &id, "Reply with exactly the word: ready");
    push_lines(&script, &TEXT_TURN.lines().collect::<Vec<_>>());
    manager.poll();

    let replay = manager.handle(AgentRequest::History {
        session_id: id.clone(),
        since: 0,
    });
    let [AgentEvent::Replay { events, is_last, truncated_at_front, .. }] = replay.as_slice() else {
        panic!("expected one replay, got {replay:?}");
    };
    let indexes: Vec<u64> = events.iter().map(|event| event.index).collect();
    assert_eq!(indexes, [1, 2, 5, 6]);
    assert!(is_last);
    assert!(!truncated_at_front);
}

#[test]
fn history_since_an_index_replays_only_what_came_after_it() {
    let (mut manager, script) = manager();
    let id = start(&mut manager, "/work/project");
    prompt(&mut manager, &id, "Reply with exactly the word: ready");
    push_lines(&script, &TEXT_TURN.lines().collect::<Vec<_>>());
    manager.poll();

    let after_two = manager.handle(AgentRequest::History {
        session_id: id.clone(),
        since: 2,
    });
    let [AgentEvent::Replay { events, .. }] = after_two.as_slice() else {
        panic!("expected one replay, got {after_two:?}");
    };
    assert_eq!(
        events.iter().map(|event| event.index).collect::<Vec<_>>(),
        [5, 6]
    );

    let caught_up = manager.handle(AgentRequest::History {
        session_id: id.clone(),
        since: 6,
    });
    assert_eq!(
        caught_up,
        [AgentEvent::Replay {
            session_id: id,
            events: Vec::new(),
            is_last: true,
            truncated_at_front: false,
        }]
    );
}

#[test]
fn history_for_a_chat_that_is_gone_fails() {
    let (mut manager, _) = manager();
    let events = manager.handle(AgentRequest::History {
        session_id: "nope".to_owned(),
        since: 0,
    });
    assert_eq!(
        events,
        [AgentEvent::Failed {
            session_id: Some("nope".to_owned()),
            message: "That chat is no longer here.".to_owned(),
        }]
    );
}

#[test]
fn an_approval_is_shown_as_waiting_and_its_answer_is_sent_back() {
    let (mut manager, script) = manager();
    let id = start(&mut manager, "/work/project");
    prompt(&mut manager, &id, "remove the file");
    push_lines(&script, &[APPROVAL_REQUEST]);
    let asked = manager.poll();
    assert!(matches!(
        streamed(&asked)[0],
        AgentStreamPayload::ApprovalRequested { .. }
    ));
    assert_eq!(state_of(&mut manager, &id), AgentSessionState::AwaitingApproval);

    let answered = manager.handle(AgentRequest::Approval {
        session_id: id.clone(),
        approval_id: APPROVAL_ID.to_owned(),
        decision: AgentApprovalDecision::Allow {},
    });
    assert_eq!(
        streamed(&answered),
        [AgentStreamPayload::ApprovalResolved {
            approval_id: APPROVAL_ID.to_owned(),
            decision: AgentApprovalDecision::Allow {},
        }]
    );
    assert_eq!(written(&script).last().expect("an answer")["type"], "control_response");
    assert_eq!(state_of(&mut manager, &id), AgentSessionState::Working);
}

#[test]
fn an_answer_to_an_ask_that_is_no_longer_waiting_is_ignored() {
    let (mut manager, script) = manager();
    let id = start(&mut manager, "/work/project");
    let events = manager.handle(AgentRequest::Approval {
        session_id: id,
        approval_id: APPROVAL_ID.to_owned(),
        decision: AgentApprovalDecision::Deny {},
    });
    assert!(events.is_empty());
    assert!(written(&script).is_empty());
}

#[test]
fn close_stops_the_process_and_forgets_the_chat() {
    let (mut manager, script) = manager();
    let id = start(&mut manager, "/work/project");
    let events = manager.handle(AgentRequest::Close { session_id: id.clone() });
    assert_eq!(events, [AgentEvent::Closed { session_id: id.clone() }]);
    assert!(lock(&script).killed);
    assert!(snapshot(&mut manager).is_empty());
    assert!(matches!(
        manager.handle(AgentRequest::History { session_id: id, since: 0 })[0],
        AgentEvent::Failed { .. }
    ));
}

#[test]
fn pause_moves_an_idle_chat_to_history_once() {
    let (mut manager, script) = manager();
    let id = start(&mut manager, "/work/project");
    let first = manager.handle(AgentRequest::Pause { session_id: id.clone() });
    assert_eq!(
        streamed(&first),
        [AgentStreamPayload::Notice {
            text: PAUSE_NOTICE.to_owned(),
        }]
    );
    assert!(lock(&script).killed);
    assert!(manager.handle(AgentRequest::Pause { session_id: id }).is_empty());
}

#[test]
fn pause_is_refused_while_a_turn_runs() {
    let (mut manager, _) = manager();
    let id = start(&mut manager, "/work/project");
    prompt(&mut manager, &id, "work on it");
    assert_eq!(
        manager.handle(AgentRequest::Pause { session_id: id.clone() }),
        [AgentEvent::Failed {
            session_id: Some(id),
            message: "Stop the turn before moving this chat to history.".to_owned(),
        }]
    );
}

#[test]
fn a_model_and_a_mode_change_are_reported_once_the_cli_confirms_them() {
    let (mut manager, script) = manager();
    let id = start(&mut manager, "/work/project");
    assert!(manager
        .handle(AgentRequest::SetModel {
            session_id: id.clone(),
            model: Some("sonnet".to_owned()),
        })
        .is_empty());
    push_lines(
        &script,
        &[r#"{"type":"control_response","response":{"subtype":"success","request_id":"peering-1","response":{"model":"claude-sonnet-4-5"}}}"#],
    );
    assert_eq!(
        manager.poll(),
        [AgentEvent::ModelChanged {
            session_id: id.clone(),
            model: Some("claude-sonnet-4-5".to_owned()),
        }]
    );

    manager.handle(AgentRequest::SetPermissionMode {
        session_id: id.clone(),
        mode: AgentPermissionMode::Plan,
    });
    push_lines(
        &script,
        &[r#"{"type":"control_response","response":{"subtype":"success","request_id":"peering-2","response":{}}}"#],
    );
    assert_eq!(
        manager.poll(),
        [AgentEvent::PermissionModeChanged {
            session_id: id.clone(),
            mode: AgentPermissionMode::Plan,
        }]
    );
    assert_eq!(snapshot(&mut manager)[0].permission_mode, Some(AgentPermissionMode::Plan));
}

#[test]
fn a_chat_whose_process_ended_says_so_and_refuses_a_prompt_it_cannot_resume() {
    let (mut manager, script) = manager();
    let id = start(&mut manager, "/work/project");
    prompt(&mut manager, &id, "hello");
    {
        let mut script = lock(&script);
        script.closed = true;
        script.exit_status = 1;
    }
    let events = manager.poll();
    assert!(streamed(&events).contains(&AgentStreamPayload::SessionExited { status: 1 }));
    assert_eq!(state_of(&mut manager, &id), AgentSessionState::Exited);

    assert_eq!(
        prompt(&mut manager, &id, "again"),
        [AgentEvent::Failed {
            session_id: Some(id),
            message: "That chat cannot be continued. Start a new one.".to_owned(),
        }]
    );
}

#[test]
fn a_chat_with_no_conversation_yet_starts_its_process_again_on_a_prompt() {
    let (mut manager, script) = manager();
    let id = start(&mut manager, "/work/project");
    {
        let mut script = lock(&script);
        script.closed = true;
    }
    manager.poll();
    assert_eq!(state_of(&mut manager, &id), AgentSessionState::Exited);

    let events = prompt(&mut manager, &id, "hello");
    assert_eq!(lock(&script).launches.len(), 2);
    assert_eq!(streamed(&events).len(), 1);
    assert_eq!(state_of(&mut manager, &id), AgentSessionState::Working);
}

#[test]
fn requests_this_host_does_not_support_yet_fail_with_one_message() {
    let (mut manager, _) = manager();
    let id = start(&mut manager, "/work/project");
    let requests = [
        AgentRequest::Browse { path: None },
        AgentRequest::ListResumable {},
        AgentRequest::Resume {
            agent_id: "claude".to_owned(),
            cli_session_id: "x".to_owned(),
        },
        AgentRequest::Changes { session_id: id.clone() },
        AgentRequest::Push { session_id: id.clone() },
    ];
    for request in requests {
        let events = manager.handle(request);
        assert!(
            matches!(&events[..], [AgentEvent::Failed { message, .. }] if message == "This is not supported on this host yet."),
            "{events:?}"
        );
    }
}

#[test]
fn an_overlong_prompt_is_refused_and_nothing_is_written() {
    let (mut manager, script) = manager();
    let id = start(&mut manager, "/work/project");
    let events = prompt(&mut manager, &id, &"x".repeat(64 * 1024 + 1));
    assert_eq!(
        events,
        [AgentEvent::Failed {
            session_id: Some(id),
            message: "That prompt is too long to send.".to_owned(),
        }]
    );
    assert!(written(&script).is_empty());
}

#[test]
fn the_snapshot_keeps_the_fields_a_client_draws_a_chat_with() {
    let (mut manager, _) = manager();
    let id = start(&mut manager, "/work/project");
    let info = snapshot(&mut manager).remove(0);
    assert_eq!(info.id, id);
    assert_eq!(info.permission_modes.as_ref().map(Vec::len), Some(4));
    assert_eq!(info.model, None);
    let mode_json: Value = serde_json::to_value(info.permission_mode).expect("serialises");
    assert_eq!(mode_json, json!("manual"));
}
