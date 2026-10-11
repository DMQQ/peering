use super::{assert_wire, SESSION_ID};
use crate::agent::AgentRequest;
use serde::Deserialize;

#[test]
fn every_request_case_round_trips() {
    let cases = [
        r#"{"list":{}}"#.to_string(),
        format!(r#"{{"history":{{"sessionID":"{SESSION_ID}","since":4}}}}"#),
        r#"{"start":{"agentID":"claude","directory":"/Users/me/app"}}"#.to_string(),
        format!(r#"{{"prompt":{{"sessionID":"{SESSION_ID}","text":"fix the bug"}}}}"#),
        format!(r#"{{"approval":{{"sessionID":"{SESSION_ID}","approvalID":"ap1","decision":{{"allow":{{}}}}}}}}"#),
        format!(r#"{{"approval":{{"sessionID":"{SESSION_ID}","approvalID":"ap2","decision":{{"choose":{{"_0":["Postgres"]}}}}}}}}"#),
        format!(r#"{{"interrupt":{{"sessionID":"{SESSION_ID}"}}}}"#),
        format!(r#"{{"setModel":{{"sessionID":"{SESSION_ID}","model":"sonnet"}}}}"#),
        format!(r#"{{"setPermissionMode":{{"sessionID":"{SESSION_ID}","mode":"acceptEdits"}}}}"#),
        format!(r#"{{"close":{{"sessionID":"{SESSION_ID}"}}}}"#),
        r#"{"browse":{"path":"/Users/me"}}"#.to_string(),
        format!(r#"{{"changes":{{"sessionID":"{SESSION_ID}"}}}}"#),
        format!(r#"{{"commit":{{"sessionID":"{SESSION_ID}","paths":["src/a.rs","README.md"],"message":"Add a"}}}}"#),
        format!(r#"{{"push":{{"sessionID":"{SESSION_ID}"}}}}"#),
        r#"{"listResumable":{}}"#.to_string(),
        r#"{"resume":{"agentID":"claude","cliSessionID":"c0ffee"}}"#.to_string(),
        format!(r#"{{"pause":{{"sessionID":"{SESSION_ID}"}}}}"#),
    ];
    for case in cases {
        assert_wire::<AgentRequest>(&case);
    }
}

#[test]
fn absent_optionals_stay_absent_in_requests() {
    assert_wire::<AgentRequest>(r#"{"start":{"agentID":"claude"}}"#);
    assert_wire::<AgentRequest>(r#"{"browse":{}}"#);
    assert_wire::<AgentRequest>(&format!(r#"{{"setModel":{{"sessionID":"{SESSION_ID}"}}}}"#));
}

#[test]
fn an_unknown_request_case_is_an_error_not_a_panic() {
    assert!(AgentRequest::deserialize(&serde_json::json!({"teleport": {}})).is_err());
}
