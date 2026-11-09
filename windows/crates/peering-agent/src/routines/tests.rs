use super::*;
use peering_wire::agent::{
    AgentEvent, AgentPermissionMode, AgentRequest, AgentRoutine, AgentRoutineOutcome, AgentRoutineSchedule, AgentSessionState,
};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

#[cfg(windows)]
const FOLDER: &str = "C:\\work";
#[cfg(not(windows))]
const FOLDER: &str = "/work";
const ID: &str = "11111111-2222-4333-8444-555555555555";
const START: i64 = 1_791_892_800;
const HOUR: i64 = 3600;

#[derive(Default)]
struct Chats {
    started: Vec<(String, String)>,
    statuses: HashMap<String, ChatStatus>,
    interrupted: Vec<String>,
    refuse_with: Option<String>,
}

impl RoutineChats for Chats {
    fn start_routine_chat(&mut self, client_id: &str, routine: &AgentRoutine) -> Result<(String, Vec<AgentEvent>), String> {
        if let Some(reason) = &self.refuse_with {
            return Err(reason.clone());
        }
        let id = format!("chat-{}", self.started.len() + 1);
        self.started.push((client_id.to_owned(), routine.name.clone()));
        self.statuses.insert(id.clone(), ChatStatus { state: Some(AgentSessionState::Working), finished_ok: None });
        Ok((id.clone(), vec![AgentEvent::Closed { session_id: id }]))
    }

    fn routine_chat_status(&self, _client_id: &str, session_id: &str) -> ChatStatus {
        self.statuses.get(session_id).copied().unwrap_or(ChatStatus { state: None, finished_ok: None })
    }

    fn interrupt_routine_chat(&mut self, _client_id: &str, session_id: &str) {
        self.interrupted.push(session_id.to_owned());
    }
}

#[derive(Clone)]
struct Machine {
    installed: Arc<Mutex<bool>>,
    has_folder: Arc<Mutex<bool>>,
}

impl RoutineEnvironment for Machine {
    fn agent_installed(&self, _agent_id: &str) -> bool {
        *self.installed.lock().expect("lock")
    }

    fn folder_exists(&self, _path: &str) -> bool {
        *self.has_folder.lock().expect("lock")
    }
}

struct Rig {
    scheduler: RoutineScheduler,
    chats: Chats,
    machine: Machine,
    storage: MemoryRoutineStorage,
}

fn rig() -> Rig {
    let storage = MemoryRoutineStorage::default();
    let machine = Machine { installed: Arc::new(Mutex::new(true)), has_folder: Arc::new(Mutex::new(true)) };
    let scheduler = RoutineScheduler::new(Box::new(storage.clone()), Box::new(machine.clone()), Box::new(FixedOffset(0)));
    Rig { scheduler, chats: Chats::default(), machine, storage }
}

fn routine(schedule: AgentRoutineSchedule) -> AgentRoutine {
    AgentRoutine {
        id: ID.to_owned(),
        name: "Review".to_owned(),
        agent_id: "claude".to_owned(),
        directory: FOLDER.to_owned(),
        prompt: "Review".to_owned(),
        schedule,
        permission_mode: AgentPermissionMode::Plan,
        is_enabled: true,
        stop_after_minutes: None,
        notifies_when_done: None,
        last_run: None,
        next_run_at: None,
    }
}

fn hourly() -> AgentRoutine {
    routine(AgentRoutineSchedule::Every { minutes: 60 })
}

impl Rig {
    fn send(&mut self, client: &str, request: AgentRequest, now: i64) -> Vec<AgentEvent> {
        self.scheduler.handle(client, &request, now, &mut self.chats).expect("a routine request")
    }

    fn save(&mut self, client: &str, routine: AgentRoutine, now: i64) -> Vec<AgentEvent> {
        self.send(client, AgentRequest::SaveRoutine { routine }, now)
    }

    fn listed(&mut self, client: &str, now: i64) -> Vec<AgentRoutine> {
        match self.send(client, AgentRequest::ListRoutines {}, now).pop() {
            Some(AgentEvent::Routines { routines }) => routines,
            other => panic!("expected the list, got {other:?}"),
        }
    }

    fn last_run(&mut self, client: &str, now: i64) -> Option<peering_wire::agent::AgentRoutineRun> {
        self.listed(client, now).first().and_then(|routine| routine.last_run.clone())
    }
}

fn failure_of(events: &[AgentEvent]) -> Option<&str> {
    events.iter().find_map(|event| match event {
        AgentEvent::Failed { message, .. } => Some(message.as_str()),
        _ => None,
    })
}

#[test]
fn a_saved_routine_is_listed_with_its_next_time_and_no_history() {
    let mut rig = rig();
    let mut incoming = hourly();
    incoming.last_run = Some(peering_wire::agent::AgentRoutineRun {
        started_at: 1.0,
        outcome: AgentRoutineOutcome::Succeeded,
        detail: None,
        session_id: None,
    });
    incoming.next_run_at = Some(5.0);
    let events = rig.save("phone", incoming, START);
    assert_eq!(failure_of(&events), None);
    let listed = rig.listed("phone", START);
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].last_run, None, "the phone's history is ignored");
    assert_eq!(listed[0].next_run_at, Some((START + HOUR) as f64 - 978_307_200.0));
}

#[test]
fn a_disabled_routine_has_no_next_time() {
    let mut rig = rig();
    let mut off = hourly();
    off.is_enabled = false;
    rig.save("phone", off, START);
    assert_eq!(rig.listed("phone", START)[0].next_run_at, None);
}

#[test]
fn a_routine_with_something_missing_is_refused_and_the_list_still_answers() {
    let mut rig = rig();
    let mut nameless = hourly();
    nameless.name = String::new();
    let events = rig.save("phone", nameless, START);
    assert_eq!(failure_of(&events), Some("That routine is missing something it needs to run."));
    assert!(matches!(events.last(), Some(AgentEvent::Routines { routines }) if routines.is_empty()));
}

#[test]
fn an_unknown_agent_or_a_mode_it_lacks_is_refused() {
    let mut rig = rig();
    let mut stranger = hourly();
    stranger.agent_id = "nobody".to_owned();
    assert_eq!(failure_of(&rig.save("phone", stranger, START)), Some("This PC no longer has that agent."));
    let mut plan_on_codex = hourly();
    plan_on_codex.agent_id = "codex".to_owned();
    plan_on_codex.permission_mode = AgentPermissionMode::Plan;
    assert_eq!(failure_of(&rig.save("phone", plan_on_codex, START)), Some("This agent cannot run in that mode."));
}

#[test]
fn a_client_keeps_at_most_thirty_routines() {
    let mut rig = rig();
    for number in 0..ROUTINES_PER_CLIENT {
        let mut one = hourly();
        one.id = format!("{number}");
        assert_eq!(failure_of(&rig.save("phone", one, START)), None);
    }
    let mut extra = hourly();
    extra.id = "extra".to_owned();
    assert!(failure_of(&rig.save("phone", extra, START)).is_some_and(|message| message.contains("as many routines")));
    assert_eq!(rig.listed("other", START).len(), 0);
}

#[test]
fn another_clients_routine_cannot_be_replaced_deleted_or_run() {
    let mut rig = rig();
    rig.save("phone", hourly(), START);
    let mut hijack = hourly();
    hijack.name = "Mine now".to_owned();
    assert_eq!(failure_of(&rig.save("other", hijack, START)), Some("That routine is no longer here."));
    rig.send("other", AgentRequest::DeleteRoutine { id: ID.to_owned() }, START);
    let events = rig.send("other", AgentRequest::RunRoutineNow { id: ID.to_owned() }, START);
    assert_eq!(failure_of(&events), Some("That routine is no longer here."));
    assert_eq!(rig.listed("phone", START)[0].name, "Review");
}

#[test]
fn a_deleted_routine_is_gone_and_stays_gone_after_a_restart() {
    let mut rig = rig();
    rig.save("phone", hourly(), START);
    rig.send("phone", AgentRequest::DeleteRoutine { id: ID.to_owned() }, START);
    assert!(rig.listed("phone", START).is_empty());
    let mut restarted = RoutineScheduler::new(Box::new(rig.storage.clone()), Box::new(rig.machine.clone()), Box::new(FixedOffset(0)));
    assert!(restarted.handle("phone", &AgentRequest::ListRoutines {}, START, &mut rig.chats).is_some());
    assert!(matches!(
        restarted.handle("phone", &AgentRequest::ListRoutines {}, START, &mut rig.chats).and_then(|mut events| events.pop()),
        Some(AgentEvent::Routines { routines }) if routines.is_empty()
    ));
}

#[test]
fn routines_survive_a_restart_with_their_history_and_owner() {
    let mut rig = rig();
    rig.save("phone", hourly(), START);
    rig.scheduler.check(START + HOUR, &mut rig.chats);
    let mut restarted = RoutineScheduler::new(Box::new(rig.storage.clone()), Box::new(rig.machine.clone()), Box::new(FixedOffset(0)));
    let Some(AgentEvent::Routines { routines }) =
        restarted.handle("phone", &AgentRequest::ListRoutines {}, START + HOUR, &mut rig.chats).and_then(|mut events| events.pop())
    else {
        panic!("the list");
    };
    assert_eq!(routines[0].last_run.as_ref().map(|run| run.outcome), Some(AgentRoutineOutcome::Running));
    let Some(AgentEvent::Routines { routines }) =
        restarted.handle("other", &AgentRequest::ListRoutines {}, START, &mut rig.chats).and_then(|mut events| events.pop())
    else {
        panic!("the list");
    };
    assert!(routines.is_empty());
}

#[test]
fn nothing_runs_before_the_interval_has_passed_and_then_the_owner_hears_of_it() {
    let mut rig = rig();
    rig.save("phone", hourly(), START);
    assert!(rig.scheduler.check(START + HOUR - 1, &mut rig.chats).is_empty());
    let events = rig.scheduler.check(START + HOUR, &mut rig.chats);
    assert_eq!(rig.chats.started, [("phone".to_owned(), "Review".to_owned())]);
    assert!(matches!(events.as_slice(), [(owner, AgentEvent::Closed { .. })] if owner == "phone"));
    let run = rig.last_run("phone", START + HOUR).expect("a run is recorded");
    assert_eq!((run.outcome, run.session_id.as_deref()), (AgentRoutineOutcome::Running, Some("chat-1")));
}

#[test]
fn a_disabled_routine_never_runs() {
    let mut rig = rig();
    let mut off = hourly();
    off.is_enabled = false;
    rig.save("phone", off, START);
    rig.scheduler.check(START + 100 * HOUR, &mut rig.chats);
    assert!(rig.chats.started.is_empty());
}

#[test]
fn a_stretch_missed_while_the_pc_slept_is_one_run() {
    let mut rig = rig();
    rig.save("phone", hourly(), START);
    rig.scheduler.check(START + 50 * HOUR, &mut rig.chats);
    rig.chats.statuses.insert("chat-1".to_owned(), ChatStatus { state: Some(AgentSessionState::Idle), finished_ok: Some(true) });
    rig.scheduler.check(START + 50 * HOUR + 60, &mut rig.chats);
    assert_eq!(rig.chats.started.len(), 1);
    rig.scheduler.check(START + 51 * HOUR + 60, &mut rig.chats);
    assert_eq!(rig.chats.started.len(), 2, "the next one is counted from when the first started");
}

#[test]
fn a_run_that_is_still_going_blocks_the_next_one() {
    let mut rig = rig();
    rig.save("phone", hourly(), START);
    rig.scheduler.check(START + HOUR, &mut rig.chats);
    rig.scheduler.check(START + 5 * HOUR, &mut rig.chats);
    assert_eq!(rig.chats.started.len(), 1);
}

#[test]
fn a_missing_agent_or_folder_records_a_skip_with_the_reason_and_still_moves_the_clock() {
    let mut rig = rig();
    rig.save("phone", hourly(), START);
    *rig.machine.installed.lock().expect("lock") = false;
    rig.scheduler.check(START + HOUR, &mut rig.chats);
    let run = rig.last_run("phone", START + HOUR).expect("a run");
    assert_eq!(run.outcome, AgentRoutineOutcome::Skipped);
    assert_eq!(run.detail.as_deref(), Some("Claude Code is not installed on this PC."));
    assert_eq!(run.session_id, None);
    *rig.machine.installed.lock().expect("lock") = true;
    *rig.machine.has_folder.lock().expect("lock") = false;
    rig.scheduler.check(START + 2 * HOUR, &mut rig.chats);
    let run = rig.last_run("phone", START + 2 * HOUR).expect("a run");
    assert!(run.detail.is_some_and(|detail| detail.starts_with("There is no folder at ")));
    assert!(rig.chats.started.is_empty());
}

#[test]
fn a_chat_that_cannot_start_is_a_skip_with_its_reason() {
    let mut rig = rig();
    rig.save("phone", hourly(), START);
    rig.chats.refuse_with = Some("This PC no longer has that agent.".to_owned());
    rig.scheduler.check(START + HOUR, &mut rig.chats);
    let run = rig.last_run("phone", START + HOUR).expect("a run");
    assert_eq!((run.outcome, run.detail.as_deref()), (AgentRoutineOutcome::Skipped, Some("This PC no longer has that agent.")));
}

fn finish(rig: &mut Rig, state: AgentSessionState, finished_ok: Option<bool>) {
    rig.chats.statuses.insert("chat-1".to_owned(), ChatStatus { state: Some(state), finished_ok });
}

#[test]
fn a_run_is_followed_to_success_failure_and_a_closed_chat() {
    for (state, ok, expected) in [
        (AgentSessionState::Idle, Some(true), AgentRoutineOutcome::Succeeded),
        (AgentSessionState::Idle, Some(false), AgentRoutineOutcome::Failed),
        (AgentSessionState::Failed, None, AgentRoutineOutcome::Failed),
    ] {
        let mut rig = rig();
        rig.save("phone", hourly(), START);
        rig.scheduler.check(START + HOUR, &mut rig.chats);
        finish(&mut rig, state, ok);
        rig.scheduler.check(START + HOUR + 30, &mut rig.chats);
        assert_eq!(rig.last_run("phone", START + HOUR + 30).map(|run| run.outcome), Some(expected), "{state:?} {ok:?}");
    }
    let mut rig = rig();
    rig.save("phone", hourly(), START);
    rig.scheduler.check(START + HOUR, &mut rig.chats);
    rig.chats.statuses.clear();
    rig.scheduler.check(START + HOUR + 30, &mut rig.chats);
    let run = rig.last_run("phone", START + HOUR + 30).expect("a run");
    assert_eq!((run.outcome, run.detail.as_deref()), (AgentRoutineOutcome::Stopped, Some("The chat was closed before the run finished.")));
}

#[test]
fn a_run_past_its_time_limit_is_interrupted_and_recorded_as_stopped() {
    let mut rig = rig();
    let mut limited = hourly();
    limited.stop_after_minutes = Some(10);
    rig.save("phone", limited, START);
    rig.scheduler.check(START + HOUR, &mut rig.chats);
    rig.scheduler.check(START + HOUR + 9 * 60, &mut rig.chats);
    assert!(rig.chats.interrupted.is_empty());
    rig.scheduler.check(START + HOUR + 10 * 60, &mut rig.chats);
    assert_eq!(rig.chats.interrupted, ["chat-1"]);
    let run = rig.last_run("phone", START + HOUR + 10 * 60).expect("a run");
    assert_eq!((run.outcome, run.detail.as_deref()), (AgentRoutineOutcome::Stopped, Some("Stopped at its limit of 10 minutes.")));
}

#[test]
fn run_now_starts_a_run_and_answers_with_its_events_and_the_list() {
    let mut rig = rig();
    rig.save("phone", hourly(), START);
    let events = rig.send("phone", AgentRequest::RunRoutineNow { id: ID.to_owned() }, START + 5);
    assert!(matches!(events.as_slice(), [AgentEvent::Closed { .. }, AgentEvent::Routines { routines }] if routines[0].last_run.is_some()));
    let again = rig.send("phone", AgentRequest::RunRoutineNow { id: ID.to_owned() }, START + 6);
    assert_eq!(failure_of(&again), Some("This routine is already running."));
    assert_eq!(rig.chats.started.len(), 1);
}

#[test]
fn saving_a_new_schedule_restarts_the_clock_and_keeps_the_history() {
    let mut rig = rig();
    rig.save("phone", hourly(), START);
    rig.scheduler.check(START + HOUR, &mut rig.chats);
    finish(&mut rig, AgentSessionState::Idle, Some(true));
    rig.scheduler.check(START + HOUR + 1, &mut rig.chats);
    let mut changed = hourly();
    changed.schedule = AgentRoutineSchedule::Every { minutes: 120 };
    rig.save("phone", changed, START + HOUR + 100);
    let listed = rig.listed("phone", START + HOUR + 100);
    assert_eq!(listed[0].last_run.as_ref().map(|run| run.outcome), Some(AgentRoutineOutcome::Succeeded));
    assert_eq!(listed[0].next_run_at, Some((START + HOUR + 100 + 2 * HOUR) as f64 - 978_307_200.0));
}

#[test]
fn an_unreadable_document_is_never_overwritten() {
    let storage = MemoryRoutineStorage::holding("{ not json");
    let machine = Machine { installed: Arc::new(Mutex::new(true)), has_folder: Arc::new(Mutex::new(true)) };
    let mut scheduler = RoutineScheduler::new(Box::new(storage.clone()), Box::new(machine), Box::new(FixedOffset(0)));
    assert!(scheduler.problem().is_some());
    let mut chats = Chats::default();
    scheduler.handle("phone", &AgentRequest::SaveRoutine { routine: hourly() }, START, &mut chats);
    assert_eq!(storage.text().as_deref(), Some("{ not json"));
}

#[test]
fn a_failed_save_is_shown_as_a_problem_and_cleared_by_the_next_good_one() {
    let mut rig = rig();
    rig.storage.fail_saves(true);
    rig.save("phone", hourly(), START);
    assert!(rig.scheduler.problem().is_some_and(|text| text.contains("could not be saved")));
    rig.storage.fail_saves(false);
    rig.save("phone", hourly(), START);
    assert_eq!(rig.scheduler.problem(), None);
}

#[test]
fn requests_that_are_not_routine_requests_are_not_answered() {
    let mut rig = rig();
    assert_eq!(rig.scheduler.handle("phone", &AgentRequest::List {}, START, &mut rig.chats), None);
}

#[test]
fn a_daily_routine_fires_at_its_local_time_on_its_weekdays() {
    let mut rig = rig();
    // START is Tuesday 2026-10-13 12:00 UTC; Wednesday is weekday 4.
    rig.save("phone", routine(AgentRoutineSchedule::Daily { hour: 9, minute: 0, weekdays: vec![4] }), START);
    rig.scheduler.check(START + 20 * HOUR, &mut rig.chats);
    assert!(rig.chats.started.is_empty(), "Wednesday 08:00");
    rig.scheduler.check(START + 21 * HOUR, &mut rig.chats);
    assert_eq!(rig.chats.started.len(), 1, "Wednesday 09:00");
}
