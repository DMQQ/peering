use super::assert_wire;
use crate::agent::{AgentEvent, AgentRequest, AgentRoutine, AgentRoutineSchedule};

const ROUTINE: &str = r#"{"id":"11111111-2222-4333-8444-555555555555","name":"Morning review","agentID":"claude","directory":"/Users/me/app","prompt":"Review yesterday's commits","schedule":{"daily":{"hour":9,"minute":30,"weekdays":[2,3,4,5,6]}},"permissionMode":"plan","isEnabled":true,"stopAfterMinutes":30,"notifiesWhenDone":false,"lastRun":{"startedAt":812979000.0,"outcome":"succeeded","detail":"ok","sessionID":"0A1B2C3D-0000-4000-8000-00000000000F"},"nextRunAt":813065400.0}"#;

#[test]
fn a_routine_with_every_field_round_trips() {
    assert_wire::<AgentRoutine>(ROUTINE);
}

#[test]
fn a_routine_saved_before_the_alert_field_existed_decodes_with_it_empty() {
    let older = r#"{"id":"11111111-2222-4333-8444-555555555555","name":"n","agentID":"codex","directory":"/x","prompt":"p","schedule":{"every":{"minutes":60}},"permissionMode":"manual","isEnabled":false}"#;
    let routine: AgentRoutine = serde_json::from_str(older).expect("decodes");
    assert_eq!(routine.notifies_when_done, None);
    assert_eq!(routine.schedule, AgentRoutineSchedule::Every { minutes: 60 });
    assert_wire::<AgentRoutine>(older);
}

#[test]
fn every_outcome_uses_the_swift_raw_value() {
    for outcome in ["running", "succeeded", "failed", "stopped", "skipped"] {
        let run = format!(r#"{{"startedAt":1.5,"outcome":"{outcome}"}}"#);
        assert_wire::<crate::agent::AgentRoutineRun>(&run);
    }
}

#[test]
fn the_four_routine_requests_round_trip() {
    let cases = [
        r#"{"listRoutines":{}}"#.to_string(),
        format!(r#"{{"saveRoutine":{{"_0":{ROUTINE}}}}}"#),
        r#"{"deleteRoutine":{"id":"11111111-2222-4333-8444-555555555555"}}"#.to_string(),
        r#"{"runRoutineNow":{"id":"11111111-2222-4333-8444-555555555555"}}"#.to_string(),
    ];
    for case in cases {
        assert_wire::<AgentRequest>(&case);
    }
}

#[test]
fn the_routines_event_round_trips() {
    assert_wire::<AgentEvent>(&format!(r#"{{"routines":{{"_0":[{ROUTINE}]}}}}"#));
    assert_wire::<AgentEvent>(r#"{"routines":{"_0":[]}}"#);
}
