use super::*;
use serde::{de::DeserializeOwned, Serialize};
use serde_json::Value;

mod events;
mod requests;

pub(super) const SESSION_ID: &str = "0A1B2C3D-0000-4000-8000-00000000000F";

/// Decodes the Swift JSON and checks that encoding the model gives the same JSON back.
pub(super) fn assert_wire<T>(json: &str)
where
    T: Serialize + DeserializeOwned,
{
    let expected: Value = serde_json::from_str(json).expect("the literal is JSON");
    let decoded: T = serde_json::from_value(expected.clone()).expect("the literal decodes");
    assert_eq!(serde_json::to_value(&decoded).expect("the model encodes"), expected);
}

const SESSION_INFO_JSON: &str = r#"{"id":"0A1B2C3D-0000-4000-8000-00000000000F","agentID":"claude","title":"Claude Code","directory":"/Users/me/app","state":"awaitingApproval","lastIndex":12,"model":"opus","permissionMode":"plan","permissionModes":["manual","acceptEdits","plan","auto"],"modelChoices":["opus","sonnet"],"usage":{"contextUsedTokens":84000,"contextWindowTokens":1000000,"inputTokens":16000,"cachedTokens":41000,"outputTokens":900,"costUSD":0.07,"limits":[{"label":"5 hours","usedFraction":0.07,"resetsAt":812979000.0}]},"createdAt":0.0}"#;

#[test]
fn a_session_listing_with_every_optional_field_round_trips() {
    assert_wire::<AgentSessionInfo>(SESSION_INFO_JSON);
}

#[test]
fn a_listing_from_an_older_mac_decodes_with_the_optional_fields_empty() {
    let older = r#"{"id":"0A1B2C3D-0000-4000-8000-00000000000F","agentID":"codex","title":"Codex","directory":"/tmp","state":"idle","lastIndex":0,"createdAt":0}"#;
    let info: AgentSessionInfo = serde_json::from_str(older).expect("the older listing decodes");
    assert_eq!(info.agent_id, "codex");
    assert_eq!(info.state, AgentSessionState::Idle);
    assert_eq!(info.usage, None);
    assert_eq!(info.permission_mode, None);
    assert_eq!(info.permission_modes, None);
    assert_eq!(info.created_at, 0.0);
    assert_wire::<AgentSessionInfo>(older.replace(r#""createdAt":0"#, r#""createdAt":0.0"#).as_str());
}

#[test]
fn an_unknown_session_state_is_an_error_not_a_panic() {
    let text = r#"{"id":"0A1B2C3D-0000-4000-8000-00000000000F","agentID":"codex","title":"x","directory":"/","state":"sleeping","lastIndex":0,"createdAt":0.0}"#;
    assert!(serde_json::from_str::<AgentSessionInfo>(text).is_err());
}

#[test]
fn an_absent_usage_key_is_not_written_back() {
    let info: AgentSessionInfo = serde_json::from_str(
        r#"{"id":"0A1B2C3D-0000-4000-8000-00000000000F","agentID":"claude","title":"t","directory":"/","state":"idle","lastIndex":3,"createdAt":1.5}"#,
    )
    .expect("decodes");
    let encoded = serde_json::to_value(&info).expect("encodes");
    assert!(encoded.get("usage").is_none());
    assert!(encoded.get("model").is_none());
}

#[test]
fn every_permission_mode_uses_the_swift_raw_value() {
    assert_wire::<AgentPermissionMode>(r#""manual""#);
    assert_wire::<AgentPermissionMode>(r#""acceptEdits""#);
    assert_wire::<AgentPermissionMode>(r#""plan""#);
    assert_wire::<AgentPermissionMode>(r#""auto""#);
}

#[test]
fn every_session_state_uses_the_swift_raw_value() {
    for state in ["idle", "working", "awaitingApproval", "exited", "failed"] {
        assert_wire::<AgentSessionState>(&format!("\"{state}\""));
    }
}

#[test]
fn usage_limits_round_trip_with_and_without_a_reset_time() {
    assert_wire::<AgentUsageLimit>(r#"{"label":"7 days","usedFraction":0.5,"resetsAt":812979000.0}"#);
    assert_wire::<AgentUsageLimit>(r#"{"label":"30 days","usedFraction":1.0}"#);
}

#[test]
fn every_approval_decision_round_trips() {
    assert_wire::<AgentApprovalDecision>(r#"{"allow":{}}"#);
    assert_wire::<AgentApprovalDecision>(r#"{"deny":{}}"#);
    assert_wire::<AgentApprovalDecision>(r#"{"choose":{"_0":["Postgres","Yes"]}}"#);
}

#[test]
fn a_tool_call_with_questions_and_a_plan_round_trips() {
    assert_wire::<AgentToolCall>(
        r#"{"id":"t1","name":"AskUserQuestion","title":"Ask","detail":"Which database?","questions":[{"header":"Store","question":"Which database?","options":[{"label":"Postgres","detail":"Relational"},{"label":"SQLite"}]}]}"#,
    );
    assert_wire::<AgentToolCall>(
        r#"{"id":"t2","name":"TodoWrite","title":"Plan","plan":[{"text":"Read the code","status":"completed"},{"text":"Write the test","status":"inProgress"},{"text":"Ship","status":"pending"}]}"#,
    );
}

#[test]
fn a_tool_call_with_a_file_and_diff_round_trips() {
    assert_wire::<AgentToolCall>(
        r#"{"id":"t3","name":"Edit","title":"Edit file","filePath":"src/main.rs","diff":"-a\n+b"}"#,
    );
}

#[test]
fn plan_status_reads_the_spellings_the_clis_use() {
    assert_eq!(AgentPlanStepStatus::from_raw(Some("in_progress")), AgentPlanStepStatus::InProgress);
    assert_eq!(AgentPlanStepStatus::from_raw(Some("inProgress")), AgentPlanStepStatus::InProgress);
    assert_eq!(AgentPlanStepStatus::from_raw(Some("done")), AgentPlanStepStatus::Completed);
    assert_eq!(AgentPlanStepStatus::from_raw(Some("COMPLETE")), AgentPlanStepStatus::Completed);
    assert_eq!(AgentPlanStepStatus::from_raw(Some("something new")), AgentPlanStepStatus::Pending);
    assert_eq!(AgentPlanStepStatus::from_raw(None), AgentPlanStepStatus::Pending);
}

#[test]
fn a_turn_summary_with_only_its_required_fields_round_trips() {
    assert_wire::<AgentTurnSummary>(r#"{"ok":true,"stopped":false}"#);
    assert_wire::<AgentTurnSummary>(
        r#"{"ok":false,"stopped":true,"costUSD":0.25,"inputTokens":10,"outputTokens":20,"duration":3.5,"model":"sonnet"}"#,
    );
}

#[test]
fn every_stream_payload_case_round_trips() {
    let cases = [
        r#"{"sessionReady":{"agentID":"claude","cliSessionID":"abc","model":"opus","directory":"/app"}}"#,
        r#"{"sessionReady":{"agentID":"codex","directory":"/app"}}"#,
        r#"{"userPrompt":{"text":"hello"}}"#,
        r#"{"turnStarted":{}}"#,
        r#"{"textDelta":{"text":"Hi"}}"#,
        r#"{"textFinal":{"text":"Hi there"}}"#,
        r#"{"toolStarted":{"call":{"id":"t1","name":"Bash","title":"Run","detail":"ls"}}}"#,
        r#"{"toolFinished":{"callID":"t1","ok":true,"output":"done","truncated":false}}"#,
        r#"{"toolFinished":{"callID":"t1","ok":false,"truncated":true}}"#,
        r#"{"approvalRequested":{"approvalID":"ap1","call":{"id":"t1","name":"Bash","title":"Run"},"reason":"needs approval"}}"#,
        r#"{"approvalResolved":{"approvalID":"ap1","decision":{"deny":{}}}}"#,
        r#"{"turnFinished":{"summary":{"ok":true,"stopped":false}}}"#,
        r#"{"notice":{"text":"Resumed"}}"#,
        r#"{"failure":{"message":"boom"}}"#,
        r#"{"sessionExited":{"status":0}}"#,
        r#"{"child":{"parentCallID":"t9","event":{"textDelta":{"text":"sub"}}}}"#,
    ];
    for case in cases {
        assert_wire::<AgentStreamPayload>(case);
    }
}

#[test]
fn a_stream_event_wraps_its_payload_with_the_index() {
    assert_wire::<AgentStreamEvent>(r#"{"index":7,"payload":{"textDelta":{"text":"Hi"}}}"#);
}

#[test]
fn an_unknown_stream_payload_case_is_an_error_not_a_panic() {
    assert!(serde_json::from_str::<AgentStreamPayload>(r#"{"somethingNew":{}}"#).is_err());
}
