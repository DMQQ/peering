//! The chat a routine runs in, against a scripted Claude process.

use super::ClientAgents;
use crate::claude_adapter::fake::{lock, push_lines, shared_script, ScriptedLauncher, SharedScript};
use crate::routines::RoutineChats;
use peering_wire::agent::{AgentEvent, AgentPermissionMode, AgentRoutine, AgentRoutineSchedule, AgentSessionState};

const TEXT_TURN: &str = include_str!("../../tests/fixtures/claude/text_turn.jsonl");
#[cfg(windows)]
const WORK_DIR: &str = "C:\\work\\project";
#[cfg(not(windows))]
const WORK_DIR: &str = "/work/project";

fn agents() -> (ClientAgents<ScriptedLauncher>, SharedScript) {
    let script = shared_script();
    let handle = script.clone();
    (ClientAgents::new(move || ScriptedLauncher::new(&handle)), script)
}

fn routine(notifies: Option<bool>) -> AgentRoutine {
    AgentRoutine {
        id: "11111111-2222-4333-8444-555555555555".to_owned(),
        name: "Morning review".to_owned(),
        agent_id: "claude".to_owned(),
        directory: WORK_DIR.to_owned(),
        prompt: "Review yesterday".to_owned(),
        schedule: AgentRoutineSchedule::Every { minutes: 60 },
        permission_mode: AgentPermissionMode::Plan,
        is_enabled: true,
        stop_after_minutes: None,
        notifies_when_done: notifies,
        last_run: None,
        next_run_at: None,
    }
}

#[test]
fn a_routine_chat_is_titled_after_the_routine_and_announced_with_its_prompt() {
    let (mut agents, script) = agents();
    let (id, events) = agents.start_routine_chat("phone", &routine(None)).expect("started");
    let [AgentEvent::Created { session }, AgentEvent::Stream { .. }] = events.as_slice() else {
        panic!("expected created then the prompt, got {events:?}");
    };
    assert_eq!((session.id.as_str(), session.title.as_str()), (id.as_str(), "Morning review"));
    assert_eq!(session.permission_mode, Some(AgentPermissionMode::Plan));
    assert_eq!(lock(&script).launches.len(), 1);
    assert!(lock(&script).written.iter().any(|line| line.contains("Review yesterday")));
}

#[test]
fn a_second_run_of_the_same_routine_gets_a_numbered_title() {
    let (mut agents, _) = agents();
    agents.start_routine_chat("phone", &routine(None)).expect("first");
    let (_, events) = agents.start_routine_chat("phone", &routine(None)).expect("second");
    assert!(matches!(&events[0], AgentEvent::Created { session } if session.title == "Morning review 2"));
}

#[test]
fn an_unknown_agent_is_refused_with_a_sentence() {
    let (mut agents, _) = agents();
    let mut unknown = routine(None);
    unknown.agent_id = "nobody".to_owned();
    assert_eq!(agents.start_routine_chat("phone", &unknown).unwrap_err(), "This PC no longer has that agent.");
}

#[test]
fn the_chat_reports_working_then_how_its_turn_ended() {
    let (mut agents, script) = agents();
    let (id, _) = agents.start_routine_chat("phone", &routine(None)).expect("started");
    let status = agents.routine_chat_status("phone", &id);
    assert_eq!((status.state, status.finished_ok), (Some(AgentSessionState::Working), None));
    push_lines(&script, &TEXT_TURN.lines().collect::<Vec<_>>());
    agents.poll();
    let status = agents.routine_chat_status("phone", &id);
    assert_eq!((status.state, status.finished_ok), (Some(AgentSessionState::Idle), Some(true)));
}

#[test]
fn a_chat_that_is_gone_or_belongs_to_someone_else_has_no_state() {
    let (mut agents, _) = agents();
    let (id, _) = agents.start_routine_chat("phone", &routine(None)).expect("started");
    assert_eq!(agents.routine_chat_status("other", &id).state, None);
    assert_eq!(agents.routine_chat_status("phone", "gone").state, None);
}

#[test]
fn a_routine_decides_whether_its_chat_pushes_a_finished_turn() {
    let (mut agents, _) = agents();
    let (default_id, _) = agents.start_routine_chat("phone", &routine(None)).expect("default");
    let (quiet_id, _) = agents.start_routine_chat("phone", &routine(Some(false))).expect("quiet");
    assert_eq!(agents.finish_alert_of("phone", &default_id), Some(true), "nil means yes");
    assert_eq!(agents.finish_alert_of("phone", &quiet_id), Some(false));
}

#[test]
fn a_chat_the_phone_started_leaves_the_alert_to_the_phones_presence() {
    use peering_wire::agent::AgentRequest;
    let (mut agents, _) = agents();
    let events = agents.handle("phone", AgentRequest::Start { agent_id: "claude".to_owned(), directory: Some(WORK_DIR.to_owned()) });
    let [AgentEvent::Created { session }] = events.as_slice() else { panic!("{events:?}") };
    assert_eq!(agents.finish_alert_of("phone", &session.id), None);
}

#[test]
fn interrupting_a_routine_chat_sends_the_cli_an_interrupt() {
    let (mut agents, script) = agents();
    let (id, _) = agents.start_routine_chat("phone", &routine(None)).expect("started");
    let before = lock(&script).written.len();
    agents.interrupt_routine_chat("phone", &id);
    assert!(lock(&script).written.len() > before);
}
