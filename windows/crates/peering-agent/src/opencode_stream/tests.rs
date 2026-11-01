use super::OpenCodeStream;
use peering_wire::agent::{AgentPlanStepStatus, AgentStreamPayload};

fn stream() -> OpenCodeStream {
    OpenCodeStream::new("/work", None)
}

#[test]
fn a_new_session_id_is_announced_once_with_the_turn_start() {
    let mut stream = stream();
    let payloads = stream.feed_line(r#"{"type":"step_start","sessionID":"ses_1","part":{}}"#);
    assert!(matches!(&payloads[0], AgentStreamPayload::SessionReady { cli_session_id: Some(id), .. } if id == "ses_1"));
    assert_eq!(payloads[1], AgentStreamPayload::TurnStarted {});
    let again = stream.feed_line(r#"{"type":"text","sessionID":"ses_1","part":{"text":"hi"}}"#);
    assert_eq!(again, vec![AgentStreamPayload::TextFinal { text: "hi".to_owned() }]);
}

#[test]
fn a_tool_step_does_not_end_the_turn_and_the_last_step_does() {
    let mut stream = stream();
    stream.feed_line(r#"{"type":"step_start","part":{}}"#);
    let tool_step = stream.feed_line(
        r#"{"type":"step_finish","part":{"reason":"tool-calls","tokens":{"input":10,"output":2,"cache":{"read":5,"write":1}}}}"#,
    );
    assert!(tool_step.is_empty());
    let last = stream.feed_line(r#"{"type":"step_finish","part":{"reason":"stop","tokens":{"input":3,"output":4}}}"#);
    let [AgentStreamPayload::TurnFinished { summary }] = last.as_slice() else { panic!("{last:?}") };
    assert_eq!((summary.input_tokens, summary.output_tokens), (Some(13), Some(6)));
    let usage = stream.usage();
    assert_eq!((usage.input_tokens, usage.cached_tokens, usage.output_tokens), (14, 5, 6));
    assert_eq!(usage.context_used_tokens, Some(7));
}

#[test]
fn a_tool_is_a_start_and_a_finish_with_its_plan_and_quiet_output() {
    let mut stream = stream();
    let payloads = stream.feed_line(
        r#"{"type":"tool_use","part":{"tool":"todowrite","callID":"t1","state":{"status":"completed","output":"x","input":{"todos":[{"content":"a","status":"in_progress"}]}}}}"#,
    );
    let [AgentStreamPayload::TurnStarted {}, AgentStreamPayload::ToolStarted { call }, AgentStreamPayload::ToolFinished { ok, output, .. }] =
        payloads.as_slice()
    else {
        panic!("{payloads:?}")
    };
    assert_eq!(call.title, "Plan");
    assert_eq!(call.plan.as_ref().map(|plan| plan[0].status), Some(AgentPlanStepStatus::InProgress));
    assert!(*ok);
    assert_eq!(*output, None);
}

#[test]
fn a_failed_command_shows_its_error() {
    let mut stream = stream();
    let payloads = stream.feed_line(
        r#"{"type":"tool_use","part":{"tool":"bash","id":"b","state":{"status":"error","error":"denied","input":{"command":"rm"}}}}"#,
    );
    assert!(matches!(&payloads[1], AgentStreamPayload::ToolStarted { call } if call.detail.as_deref() == Some("rm")));
    assert!(matches!(&payloads[2], AgentStreamPayload::ToolFinished { ok: false, output: Some(text), .. } if text == "denied"));
}

#[test]
fn an_error_ends_the_turn_with_its_message() {
    let mut stream = stream();
    let payloads = stream.feed_line(r#"{"type":"error","error":{"name":"APIError","data":{"message":"bad key"}}}"#);
    assert_eq!(payloads[1], AgentStreamPayload::Notice { text: "bad key".to_owned() });
    assert!(matches!(&payloads[2], AgentStreamPayload::TurnFinished { summary } if !summary.ok));
}
