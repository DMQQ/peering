//! Call shapes, sub-agent routing, output limits and usage.

use super::tests::{assert_close, feed_one, tool_call_of};
use super::ClaudeStream;
use peering_wire::agent::AgentStreamPayload;

#[test]
fn several_questions_are_all_carried() {
    let ask = r#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Colour?","header":"Colour","options":[{"label":"Red"}]},{"question":"Size?","header":"Size","options":[{"label":"Small"},{"label":"Large"}]},{"question":"Shape?","header":"Shape","options":[{"label":"Round"}]}]},"tool_use_id":"t"}}"#;
    let payloads = feed_one(ask);
    let questions = tool_call_of(&payloads[0]).questions.clone().expect("questions");
    let texts: Vec<&str> = questions.iter().map(|question| question.question.as_str()).collect();
    assert_eq!(texts, ["Colour?", "Size?", "Shape?"]);
    let sizes: Vec<&str> = questions[1].options.iter().map(|option| option.label.as_str()).collect();
    assert_eq!(sizes, ["Small", "Large"]);
}

#[test]
fn edit_builds_a_diff_and_names_the_file() {
    let edit = r#"{"type":"assistant","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"toolu_02","name":"Edit","input":{"file_path":"/app/src/a.ts","old_string":"const a = 1;","new_string":"const a = 2;"}}]},"parent_tool_use_id":null,"session_id":"s","uuid":"u5"}"#;
    let payloads = feed_one(edit);
    let call = tool_call_of(&payloads[0]);
    assert_eq!(call.file_path.as_deref(), Some("/app/src/a.ts"));
    assert_eq!(call.detail.as_deref(), Some("/app/src/a.ts"));
    let diff = call.diff.as_deref().expect("diff");
    assert!(diff.contains("--- /app/src/a.ts"), "{diff}");
    assert!(diff.contains("-const a = 1;"), "{diff}");
    assert!(diff.contains("+const a = 2;"), "{diff}");
}

#[test]
fn subagent_traffic_is_filed_under_its_parent() {
    let subagent_tool = r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"ls"}}]},"parent_tool_use_id":"toolu_parent","session_id":"s","uuid":"u6"}"#;
    let subagent_delta = r#"{"type":"stream_event","parent_tool_use_id":"toolu_parent","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}}"#;
    let mut stream = ClaudeStream::new();
    let mut payloads = stream.feed_line(subagent_tool);
    payloads.extend(stream.feed_line(subagent_delta));

    assert_eq!(payloads.len(), 2);
    for payload in &payloads {
        let AgentStreamPayload::Child { parent_call_id, .. } = payload else {
            panic!("expected child, got {payload:?}");
        };
        assert_eq!(parent_call_id, "toolu_parent");
    }
}

#[test]
fn long_tool_output_is_cut_to_the_budget() {
    let long = "x".repeat(40_000);
    let line = format!(
        r#"{{"type":"user","message":{{"role":"user","content":[{{"tool_use_id":"t1","type":"tool_result","content":"{long}"}}]}},"parent_tool_use_id":null,"session_id":"s"}}"#
    );
    let payloads = feed_one(&line);
    let AgentStreamPayload::ToolFinished { output, truncated, .. } = &payloads[0] else {
        panic!("expected toolFinished, got {:?}", payloads[0]);
    };
    assert!(truncated);
    assert_eq!(output.as_ref().map(String::len), Some(32 * 1024));
}

#[test]
fn usage_accumulates_per_turn_and_limits_are_read_in_order() {
    let mut stream = ClaudeStream::new();
    let call = r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":100,"cache_read_input_tokens":50,"cache_creation_input_tokens":10,"output_tokens":5}},"parent_tool_use_id":null,"session_id":"s"}"#;
    stream.feed_line(call);
    assert_eq!(stream.usage().context_used_tokens, Some(165));

    let result = r#"{"type":"result","subtype":"success","is_error":false,"duration_ms":10,"total_cost_usd":0.5,"usage":{"input_tokens":1000,"cache_read_input_tokens":500,"output_tokens":20},"modelUsage":{"m":{"contextWindow":200000}},"terminal_reason":"completed","session_id":"s"}"#;
    stream.feed_line(result);
    let usage = stream.usage();
    assert_eq!(usage.input_tokens, 1000);
    assert_eq!(usage.cached_tokens, 500);
    assert_eq!(usage.output_tokens, 20);
    assert_close(usage.cost_usd, 0.5);
    assert_eq!(usage.context_window_tokens, Some(200_000));

    let limits = r#"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"seven_day":{"utilization":0.4,"resetsAt":1000000000},"five_hour":{"utilization":1.5,"resetsAt":1000003600}}}}"#;
    assert!(stream.feed_line(limits).is_empty());
    let windows = &stream.usage().limits;
    assert_eq!(windows.len(), 2);
    assert_eq!(windows[0].label, "5 hours");
    assert_close(Some(windows[0].used_fraction), 1.0);
    assert_close(windows[0].resets_at, 21_696_400.0);
    assert_eq!(windows[1].label, "7 days");
    assert_close(Some(windows[1].used_fraction), 0.4);
}
