//! Keeps the routines, fires each one when it is due, and follows its run to the end. Mirrors `AgentRoutineScheduler.swift`.
//!
//! The scheduler owns no clock and no process: the host calls `check` with the time, and the chats are reached through
//! `RoutineChats`, so tests drive both.

use super::plan::{is_due, UtcOffset};
use super::progress::{progress_of, RoutineProgress};
use super::storage::{self, RoutineEntry, RoutineStorage};
use crate::adapter::agent_name;
use peering_wire::agent::{AgentEvent, AgentRoutine, AgentRoutineOutcome, AgentRoutineRun, AgentSessionState};

pub const ROUTINES_PER_CLIENT: usize = 30;
/// Seconds from the Unix epoch to 2001-01-01, the reference date the wire's times count from.
const UNIX_TO_REFERENCE_SECONDS: f64 = 978_307_200.0;

/// How a routine's chat has got on: its state (`None` once it is gone) and how its last turn ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ChatStatus {
    pub state: Option<AgentSessionState>,
    pub finished_ok: Option<bool>,
}

/// The chats routines run in, which belong to the client that owns the routine.
pub trait RoutineChats {
    /// Starts a chat that sends the routine's prompt and returns its id with the events that announce it. The folder and
    /// the binary are checked by the caller.
    fn start_routine_chat(&mut self, client_id: &str, routine: &AgentRoutine) -> Result<(String, Vec<AgentEvent>), String>;
    fn routine_chat_status(&self, client_id: &str, session_id: &str) -> ChatStatus;
    fn interrupt_routine_chat(&mut self, client_id: &str, session_id: &str);
}

/// What the PC has, asked only when a run is about to start.
pub trait RoutineEnvironment {
    fn agent_installed(&self, agent_id: &str) -> bool;
    fn folder_exists(&self, path: &str) -> bool;
}

pub struct RoutineScheduler {
    pub(super) entries: Vec<RoutineEntry>,
    /// False when the stored document could not be read: nothing is saved over it.
    pub(super) readable: bool,
    pub(super) storage: Box<dyn RoutineStorage + Send>,
    pub(super) environment: Box<dyn RoutineEnvironment + Send>,
    pub(super) zone: Box<dyn UtcOffset + Send>,
    pub(super) problem: Option<String>,
}

impl RoutineScheduler {
    pub fn new(
        storage: Box<dyn RoutineStorage + Send>,
        environment: Box<dyn RoutineEnvironment + Send>,
        zone: Box<dyn UtcOffset + Send>,
    ) -> Self {
        let loaded = storage.load().and_then(|text| text.map_or_else(|| Ok(Vec::new()), |text| storage::decode(&text)));
        let (entries, readable, problem) = match loaded {
            Ok(entries) => (entries, true, None),
            Err(error) => (Vec::new(), false, Some(format!("The saved routines could not be read ({error}), so none are shown."))),
        };
        Self { entries, readable, storage, environment, zone, problem }
    }

    /// Why the saved routines were not loaded, for the host to show as a problem.
    pub fn problem(&self) -> Option<&str> {
        self.problem.as_deref()
    }

    /// Records how running runs have got on, then starts what is due. Each event comes with the client it is for.
    pub fn check(&mut self, now: i64, chats: &mut dyn RoutineChats) -> Vec<(String, AgentEvent)> {
        let mut changed = false;
        for index in 0..self.entries.len() {
            changed |= self.follow(index, now, chats);
        }
        let mut events = Vec::new();
        for index in 0..self.entries.len() {
            if self.is_due(index, now) {
                let owner = self.entries[index].owner_client_id.clone();
                events.extend(self.fire(index, now, chats).into_iter().map(|event| (owner.clone(), event)));
                changed = true;
            }
        }
        if changed {
            self.save();
        }
        events
    }

    fn is_due(&self, index: usize, now: i64) -> bool {
        let entry = &self.entries[index];
        entry.routine.is_enabled
            && !is_running(&entry.routine)
            && is_due(&entry.routine.schedule, entry.scheduled_from, now, self.zone.as_ref())
    }

    /// Records how a running run has got on. True when the record changed.
    fn follow(&mut self, index: usize, now: i64, chats: &mut dyn RoutineChats) -> bool {
        let entry = &self.entries[index];
        let Some(run) = entry.routine.last_run.as_ref().filter(|run| run.outcome == AgentRoutineOutcome::Running) else {
            return false;
        };
        let Some(session_id) = run.session_id.clone() else {
            return false;
        };
        let owner = entry.owner_client_id.clone();
        let limit = entry.routine.stop_after_minutes;
        let started = unix_of(run.started_at);
        let status = chats.routine_chat_status(&owner, &session_id);
        match progress_of(status.state, status.finished_ok, started, now, limit) {
            RoutineProgress::Running => return false,
            RoutineProgress::OverTime => {
                chats.interrupt_routine_chat(&owner, &session_id);
                let minutes = limit.unwrap_or(0);
                let spent = if minutes == 1 { "1 minute".to_owned() } else { format!("{minutes} minutes") };
                self.record(index, AgentRoutineOutcome::Stopped, Some(format!("Stopped at its limit of {spent}.")));
            }
            RoutineProgress::Ended(outcome) => self.record(index, outcome, detail_for(outcome)),
        }
        true
    }

    fn record(&mut self, index: usize, outcome: AgentRoutineOutcome, detail: Option<String>) {
        if let Some(run) = self.entries[index].routine.last_run.as_mut() {
            run.outcome = outcome;
            run.detail = detail;
        }
    }

    /// Starts a run, or records why it could not. Either way the next time is counted from now, so a missed stretch is one run.
    pub(super) fn fire(&mut self, index: usize, now: i64, chats: &mut dyn RoutineChats) -> Vec<AgentEvent> {
        let routine = self.entries[index].routine.clone();
        let owner = self.entries[index].owner_client_id.clone();
        self.entries[index].scheduled_from = now;
        let skipped = |reason: String| AgentRoutineRun {
            started_at: reference_of(now),
            outcome: AgentRoutineOutcome::Skipped,
            detail: Some(reason),
            session_id: None,
        };
        if let Some(reason) = self.reason_to_skip(&routine) {
            self.entries[index].routine.last_run = Some(skipped(reason));
            return Vec::new();
        }
        match chats.start_routine_chat(&owner, &routine) {
            Ok((session_id, events)) => {
                self.entries[index].routine.last_run = Some(AgentRoutineRun {
                    started_at: reference_of(now),
                    outcome: AgentRoutineOutcome::Running,
                    detail: None,
                    session_id: Some(session_id),
                });
                events
            }
            Err(reason) => {
                self.entries[index].routine.last_run = Some(skipped(reason));
                Vec::new()
            }
        }
    }

    fn reason_to_skip(&self, routine: &AgentRoutine) -> Option<String> {
        let name = agent_name(&routine.agent_id).unwrap_or(&routine.agent_id);
        if !self.environment.agent_installed(&routine.agent_id) {
            return Some(format!("{name} is not installed on this PC."));
        }
        (!self.environment.folder_exists(&routine.directory)).then(|| format!("There is no folder at {} on this PC.", routine.directory))
    }

    /// Writes the document, unless it was unreadable at the start. A failure is kept as the problem the host shows.
    pub(super) fn save(&mut self) {
        if !self.readable {
            return;
        }
        let written = storage::encode(&self.entries).and_then(|text| self.storage.save(&text));
        self.problem = written.err().map(|error| format!("The routines could not be saved ({error})."));
    }
}

pub(super) fn is_running(routine: &AgentRoutine) -> bool {
    routine.last_run.as_ref().is_some_and(|run| run.outcome == AgentRoutineOutcome::Running)
}

fn detail_for(outcome: AgentRoutineOutcome) -> Option<String> {
    match outcome {
        AgentRoutineOutcome::Failed => Some("The agent did not finish the run.".to_owned()),
        AgentRoutineOutcome::Stopped => Some("The chat was closed before the run finished.".to_owned()),
        AgentRoutineOutcome::Running | AgentRoutineOutcome::Succeeded | AgentRoutineOutcome::Skipped => None,
    }
}

pub(super) fn reference_of(unix: i64) -> f64 {
    unix as f64 - UNIX_TO_REFERENCE_SECONDS
}

pub(super) fn unix_of(reference: f64) -> i64 {
    (reference + UNIX_TO_REFERENCE_SECONDS) as i64
}
