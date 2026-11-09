//! Where a routine's run has got to, read from its chat. Mirrors `AgentRoutineProgress.swift`.

use peering_wire::agent::{AgentRoutineOutcome, AgentSessionState};

/// A chat that was never seen working and has stayed idle this long did not start its turn.
pub const START_GRACE_SECONDS: i64 = 10 * 60;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RoutineProgress {
    Running,
    /// Over the routine's own time limit: the host stops the turn and records the run as stopped.
    OverTime,
    Ended(AgentRoutineOutcome),
}

/// `state` is `None` when the chat is gone; `finished_ok` is how the chat's last turn ended, `None` while no turn has.
pub fn progress_of(
    state: Option<AgentSessionState>,
    finished_ok: Option<bool>,
    started_at: i64,
    now: i64,
    stop_after_minutes: Option<i64>,
) -> RoutineProgress {
    let Some(state) = state else {
        return RoutineProgress::Ended(AgentRoutineOutcome::Stopped);
    };
    let busy = matches!(state, AgentSessionState::Working | AgentSessionState::AwaitingApproval);
    if let Some(limit) = stop_after_minutes {
        if now - started_at >= limit.saturating_mul(60) {
            return if busy { RoutineProgress::OverTime } else { RoutineProgress::Ended(outcome(finished_ok)) };
        }
    }
    match state {
        AgentSessionState::Working | AgentSessionState::AwaitingApproval => RoutineProgress::Running,
        AgentSessionState::Failed => RoutineProgress::Ended(AgentRoutineOutcome::Failed),
        AgentSessionState::Exited => RoutineProgress::Ended(outcome(finished_ok)),
        AgentSessionState::Idle => match finished_ok {
            Some(true) => RoutineProgress::Ended(AgentRoutineOutcome::Succeeded),
            Some(false) => RoutineProgress::Ended(AgentRoutineOutcome::Failed),
            None if now - started_at >= START_GRACE_SECONDS => RoutineProgress::Ended(AgentRoutineOutcome::Failed),
            None => RoutineProgress::Running,
        },
    }
}

fn outcome(finished_ok: Option<bool>) -> AgentRoutineOutcome {
    if finished_ok == Some(true) { AgentRoutineOutcome::Succeeded } else { AgentRoutineOutcome::Failed }
}

#[cfg(test)]
mod tests {
    use super::*;
    use AgentRoutineOutcome::*;
    use AgentSessionState as State;

    fn of(state: Option<State>, ok: Option<bool>, elapsed: i64, limit: Option<i64>) -> RoutineProgress {
        progress_of(state, ok, 1000, 1000 + elapsed, limit)
    }

    #[test]
    fn a_chat_that_is_gone_was_stopped() {
        assert_eq!(of(None, None, 5, None), RoutineProgress::Ended(Stopped));
    }

    #[test]
    fn a_working_chat_is_running_until_its_limit_and_then_over_time() {
        assert_eq!(of(Some(State::Working), None, 59 * 60, Some(1)), RoutineProgress::OverTime);
        assert_eq!(of(Some(State::AwaitingApproval), None, 30, Some(1)), RoutineProgress::Running);
        assert_eq!(of(Some(State::Working), None, 60, Some(1)), RoutineProgress::OverTime);
        assert_eq!(of(Some(State::Working), None, 99_999, None), RoutineProgress::Running);
    }

    #[test]
    fn an_idle_chat_past_its_limit_ends_by_how_its_turn_ended() {
        assert_eq!(of(Some(State::Idle), Some(true), 120, Some(1)), RoutineProgress::Ended(Succeeded));
        assert_eq!(of(Some(State::Idle), None, 120, Some(1)), RoutineProgress::Ended(Failed));
    }

    #[test]
    fn a_finished_turn_decides_the_outcome() {
        assert_eq!(of(Some(State::Idle), Some(true), 5, None), RoutineProgress::Ended(Succeeded));
        assert_eq!(of(Some(State::Idle), Some(false), 5, None), RoutineProgress::Ended(Failed));
        assert_eq!(of(Some(State::Exited), Some(true), 5, None), RoutineProgress::Ended(Succeeded));
        assert_eq!(of(Some(State::Exited), None, 5, None), RoutineProgress::Ended(Failed));
        assert_eq!(of(Some(State::Failed), Some(true), 5, None), RoutineProgress::Ended(Failed));
    }

    #[test]
    fn an_idle_chat_that_never_began_gets_a_grace_period() {
        assert_eq!(of(Some(State::Idle), None, START_GRACE_SECONDS - 1, None), RoutineProgress::Running);
        assert_eq!(of(Some(State::Idle), None, START_GRACE_SECONDS, None), RoutineProgress::Ended(Failed));
    }
}
