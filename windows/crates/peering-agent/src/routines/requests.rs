//! The phone's routine requests. Each is answered with the owner's whole list. Mirrors `AgentRoutineScheduler+Requests.swift`.

use super::plan::next_fire;
use super::scheduler::{is_running, reference_of, RoutineChats, RoutineScheduler, ROUTINES_PER_CLIENT};
use super::storage::RoutineEntry;
use super::validation::problem_with;
use crate::adapter::{agent_name, permission_modes_of};
use peering_wire::agent::{AgentEvent, AgentRequest, AgentRoutine};

const MISSING_SOMETHING: &str = "That routine is missing something it needs to run.";
const NO_SUCH_AGENT: &str = "This PC no longer has that agent.";
const NO_SUCH_MODE: &str = "This agent cannot run in that mode.";
const GONE: &str = "That routine is no longer here.";
const ALREADY_RUNNING: &str = "This routine is already running.";
const FULL: &str = "This PC already keeps as many routines as it can.";

impl RoutineScheduler {
    /// The events that answer a routine request, or `None` for any other request.
    pub fn handle(&mut self, client_id: &str, request: &AgentRequest, now: i64, chats: &mut dyn RoutineChats) -> Option<Vec<AgentEvent>> {
        let mut events = Vec::new();
        let failure = match request {
            AgentRequest::ListRoutines {} => None,
            AgentRequest::SaveRoutine { routine } => self.save_routine(routine, client_id, now).err(),
            AgentRequest::DeleteRoutine { id } => {
                self.entries.retain(|entry| !(entry.routine.id == *id && entry.owner_client_id == client_id));
                self.save();
                None
            }
            AgentRequest::RunRoutineNow { id } => match self.run_now(id, client_id, now, chats) {
                Ok(started) => {
                    events = started;
                    None
                }
                Err(message) => Some(message),
            },
            _ => return None,
        };
        if let Some(message) = failure {
            events.push(AgentEvent::Failed { session_id: None, message: message.to_owned() });
        }
        events.push(AgentEvent::Routines { routines: self.routines_of(client_id) });
        Some(events)
    }

    /// The phone's copy carries no run history: what the host recorded is kept.
    fn save_routine(&mut self, incoming: &AgentRoutine, client_id: &str, now: i64) -> Result<(), &'static str> {
        if problem_with(incoming).is_some() {
            return Err(MISSING_SOMETHING);
        }
        if agent_name(&incoming.agent_id).is_none() {
            return Err(NO_SUCH_AGENT);
        }
        if !permission_modes_of(&incoming.agent_id).is_some_and(|modes| modes.contains(&incoming.permission_mode)) {
            return Err(NO_SUCH_MODE);
        }
        let mut routine = incoming.clone();
        routine.next_run_at = None;
        if let Some(entry) = self.entries.iter_mut().find(|entry| entry.routine.id == routine.id) {
            if entry.owner_client_id != client_id {
                return Err(GONE);
            }
            routine.last_run = entry.routine.last_run.clone();
            let rescheduled = routine.schedule != entry.routine.schedule || (routine.is_enabled && !entry.routine.is_enabled);
            entry.routine = routine;
            if rescheduled {
                entry.scheduled_from = now;
            }
        } else {
            if self.entries.iter().filter(|entry| entry.owner_client_id == client_id).count() >= ROUTINES_PER_CLIENT {
                return Err(FULL);
            }
            routine.last_run = None;
            self.entries.push(RoutineEntry { owner_client_id: client_id.to_owned(), routine, scheduled_from: now });
        }
        self.save();
        Ok(())
    }

    fn run_now(&mut self, id: &str, client_id: &str, now: i64, chats: &mut dyn RoutineChats) -> Result<Vec<AgentEvent>, &'static str> {
        let index = self
            .entries
            .iter()
            .position(|entry| entry.routine.id == id && entry.owner_client_id == client_id)
            .ok_or(GONE)?;
        if is_running(&self.entries[index].routine) {
            return Err(ALREADY_RUNNING);
        }
        let events = self.fire(index, now, chats);
        self.save();
        Ok(events)
    }

    fn routines_of(&self, client_id: &str) -> Vec<AgentRoutine> {
        self.entries
            .iter()
            .filter(|entry| entry.owner_client_id == client_id)
            .map(|entry| {
                let mut routine = entry.routine.clone();
                routine.next_run_at = routine
                    .is_enabled
                    .then(|| next_fire(&routine.schedule, entry.scheduled_from, self.zone.as_ref()))
                    .flatten()
                    .map(reference_of);
                routine
            })
            .collect()
    }
}
