use super::{assert_wire, SESSION_ID};
use crate::agent::AgentEvent;
use serde::Deserialize;

#[test]
fn snapshot_and_created_round_trip_their_sessions() {
    let session = super::SESSION_INFO_JSON;
    assert_wire::<AgentEvent>(&format!(r#"{{"snapshot":{{"_0":[{session}]}}}}"#));
    assert_wire::<AgentEvent>(r#"{"snapshot":{"_0":[]}}"#);
    assert_wire::<AgentEvent>(&format!(r#"{{"created":{{"_0":{session}}}}}"#));
}

#[test]
fn every_event_case_round_trips() {
    let cases = [
        format!(r#"{{"stream":{{"sessionID":"{SESSION_ID}","event":{{"index":1,"payload":{{"turnStarted":{{}}}}}}}}}}"#),
        format!(
            r#"{{"replay":{{"sessionID":"{SESSION_ID}","events":[{{"index":1,"payload":{{"userPrompt":{{"text":"hi"}}}}}}],"isLast":true,"truncatedAtFront":false}}}}"#
        ),
        r#"{"directory":{"path":"/Users/me","entries":[{"name":"src","isDirectory":true,"isSymlink":false,"size":0,"permissions":"drwxr-xr-x","modified":812979000.0}],"truncated":false}}"#.to_string(),
        r#"{"browseFailure":{"path":"/root","message":"Denied"}}"#.to_string(),
        r#"{"browseWaiting":{"path":"/Desktop","message":"Waiting for permission"}}"#.to_string(),
        format!(r#"{{"changes":{{"sessionID":"{SESSION_ID}","report":{{"branch":"main","files":[]}}}}}}"#),
        format!(r#"{{"gitResult":{{"sessionID":"{SESSION_ID}","result":{{"ok":true,"message":"Committed"}}}}}}"#),
        format!(r#"{{"closed":{{"sessionID":"{SESSION_ID}"}}}}"#),
        format!(r#"{{"modelChanged":{{"sessionID":"{SESSION_ID}","model":"opus"}}}}"#),
        format!(r#"{{"permissionModeChanged":{{"sessionID":"{SESSION_ID}","mode":"plan"}}}}"#),
        format!(
            r#"{{"usageChanged":{{"sessionID":"{SESSION_ID}","usage":{{"inputTokens":5,"cachedTokens":0,"outputTokens":9,"limits":[]}}}}}}"#
        ),
        r#"{"failed":{"message":"No Mac answered"}}"#.to_string(),
        format!(r#"{{"failed":{{"sessionID":"{SESSION_ID}","message":"Process crashed"}}}}"#),
        r#"{"resumable":{"_0":[{"agentID":"claude","cliSessionID":"c0ffee","title":"Refactor"}]}}"#.to_string(),
        r#"{"resumable":{"_0":[]}}"#.to_string(),
    ];
    for case in cases {
        assert_wire::<AgentEvent>(&case);
    }
}

#[test]
fn an_absent_model_in_model_changed_decodes_as_the_cli_default() {
    let event: AgentEvent =
        serde_json::from_str(&format!(r#"{{"modelChanged":{{"sessionID":"{SESSION_ID}"}}}}"#)).expect("decodes");
    assert_eq!(
        event,
        AgentEvent::ModelChanged { session_id: SESSION_ID.to_string(), model: None }
    );
}

#[test]
fn an_unknown_event_case_is_an_error_not_a_panic() {
    assert!(AgentEvent::deserialize(&serde_json::json!({"teleport": {}})).is_err());
}
