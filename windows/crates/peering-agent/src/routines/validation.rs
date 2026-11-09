//! What makes a routine one the host refuses to keep. Mirrors `AgentRoutineValidation.swift`.

use peering_wire::agent::{AgentRoutine, AgentRoutineSchedule};
use std::path::Path;

pub const NAME_LIMIT: usize = 80;
pub const PROMPT_BYTES_LIMIT: usize = 64 * 1024;
/// Shorter than this, a run would still be going when the next is due.
pub const MINIMUM_INTERVAL_MINUTES: i64 = 15;
pub const MAXIMUM_INTERVAL_MINUTES: i64 = 7 * 24 * 60;
pub const MAXIMUM_STOP_AFTER_MINUTES: i64 = 12 * 60;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RoutineProblem {
    MissingName,
    NameTooLong,
    MissingPrompt,
    PromptTooLong,
    RelativeFolder,
    IntervalOutOfRange,
    TimeOutOfRange,
    NoWeekdays,
    StopAfterOutOfRange,
}

/// The first problem found, or `None` for a routine that can be kept.
pub fn problem_with(routine: &AgentRoutine) -> Option<RoutineProblem> {
    let name = routine.name.trim();
    if name.is_empty() {
        return Some(RoutineProblem::MissingName);
    }
    if name.chars().count() > NAME_LIMIT {
        return Some(RoutineProblem::NameTooLong);
    }
    if routine.prompt.trim().is_empty() {
        return Some(RoutineProblem::MissingPrompt);
    }
    if routine.prompt.len() > PROMPT_BYTES_LIMIT {
        return Some(RoutineProblem::PromptTooLong);
    }
    if !Path::new(&routine.directory).is_absolute() {
        return Some(RoutineProblem::RelativeFolder);
    }
    if let Some(problem) = schedule_problem(&routine.schedule) {
        return Some(problem);
    }
    match routine.stop_after_minutes {
        Some(limit) if !(1..=MAXIMUM_STOP_AFTER_MINUTES).contains(&limit) => Some(RoutineProblem::StopAfterOutOfRange),
        _ => None,
    }
}

fn schedule_problem(schedule: &AgentRoutineSchedule) -> Option<RoutineProblem> {
    match schedule {
        AgentRoutineSchedule::Every { minutes } => {
            (!(MINIMUM_INTERVAL_MINUTES..=MAXIMUM_INTERVAL_MINUTES).contains(minutes)).then_some(RoutineProblem::IntervalOutOfRange)
        }
        AgentRoutineSchedule::Daily { hour, minute, weekdays } => {
            if !(0..=23).contains(hour) || !(0..=59).contains(minute) {
                return Some(RoutineProblem::TimeOutOfRange);
            }
            let valid = weekdays.iter().filter(|day| (1..=7).contains(*day)).count();
            (valid == 0 || valid != weekdays.len()).then_some(RoutineProblem::NoWeekdays)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use peering_wire::agent::AgentPermissionMode;

    #[cfg(windows)]
    const FOLDER: &str = "C:\\work";
    #[cfg(not(windows))]
    const FOLDER: &str = "/work";

    fn routine() -> AgentRoutine {
        AgentRoutine {
            id: "11111111-2222-4333-8444-555555555555".to_owned(),
            name: "Review".to_owned(),
            agent_id: "claude".to_owned(),
            directory: FOLDER.to_owned(),
            prompt: "Review".to_owned(),
            schedule: AgentRoutineSchedule::Every { minutes: 60 },
            permission_mode: AgentPermissionMode::Plan,
            is_enabled: true,
            stop_after_minutes: None,
            notifies_when_done: None,
            last_run: None,
            next_run_at: None,
        }
    }

    fn with(change: impl FnOnce(&mut AgentRoutine)) -> Option<RoutineProblem> {
        let mut routine = routine();
        change(&mut routine);
        problem_with(&routine)
    }

    #[test]
    fn a_complete_routine_has_no_problem() {
        assert_eq!(problem_with(&routine()), None);
    }

    #[test]
    fn a_name_and_prompt_must_say_something_and_stay_short() {
        assert_eq!(with(|r| r.name = "  ".to_owned()), Some(RoutineProblem::MissingName));
        assert_eq!(with(|r| r.name = "x".repeat(81)), Some(RoutineProblem::NameTooLong));
        assert_eq!(with(|r| r.prompt = "\n".to_owned()), Some(RoutineProblem::MissingPrompt));
        assert_eq!(with(|r| r.prompt = "x".repeat(PROMPT_BYTES_LIMIT + 1)), Some(RoutineProblem::PromptTooLong));
    }

    #[test]
    fn the_folder_must_be_absolute() {
        assert_eq!(with(|r| r.directory = "work".to_owned()), Some(RoutineProblem::RelativeFolder));
    }

    #[test]
    fn an_interval_stays_between_fifteen_minutes_and_a_week() {
        let every = |minutes| move |r: &mut AgentRoutine| r.schedule = AgentRoutineSchedule::Every { minutes };
        assert_eq!(with(every(14)), Some(RoutineProblem::IntervalOutOfRange));
        assert_eq!(with(every(15)), None);
        assert_eq!(with(every(MAXIMUM_INTERVAL_MINUTES)), None);
        assert_eq!(with(every(MAXIMUM_INTERVAL_MINUTES + 1)), Some(RoutineProblem::IntervalOutOfRange));
    }

    #[test]
    fn a_daily_time_needs_a_real_clock_time_and_only_real_weekdays() {
        let daily = |hour, minute, weekdays: &[i64]| {
            let weekdays = weekdays.to_vec();
            move |r: &mut AgentRoutine| r.schedule = AgentRoutineSchedule::Daily { hour, minute, weekdays }
        };
        assert_eq!(with(daily(24, 0, &[1])), Some(RoutineProblem::TimeOutOfRange));
        assert_eq!(with(daily(0, 60, &[1])), Some(RoutineProblem::TimeOutOfRange));
        assert_eq!(with(daily(9, 0, &[])), Some(RoutineProblem::NoWeekdays));
        assert_eq!(with(daily(9, 0, &[1, 8])), Some(RoutineProblem::NoWeekdays));
        assert_eq!(with(daily(23, 59, &[1, 7])), None);
    }

    #[test]
    fn a_time_limit_stays_within_twelve_hours() {
        assert_eq!(with(|r| r.stop_after_minutes = Some(0)), Some(RoutineProblem::StopAfterOutOfRange));
        assert_eq!(with(|r| r.stop_after_minutes = Some(721)), Some(RoutineProblem::StopAfterOutOfRange));
        assert_eq!(with(|r| r.stop_after_minutes = Some(720)), None);
    }
}
