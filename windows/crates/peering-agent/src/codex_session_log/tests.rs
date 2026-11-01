use super::{label_for_minutes, read_usage, usage_from_log, visible_models, LogLookup};
use std::fs;

const LOG: &str = concat!(
    r#"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#,
    "\n",
    r#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":300,"output_tokens":50},"last_token_usage":{"total_tokens":4200},"model_context_window":272000},"rate_limits":{"primary":{"used_percent":12.5,"window_minutes":300,"resets_at":978307300},"secondary":{"used_percent":140,"window_minutes":10080}}}}"#,
    "\n"
);

#[test]
fn the_last_token_count_gives_context_totals_and_limits() {
    let usage = usage_from_log(LOG).expect("a token count");
    assert_eq!((usage.input_tokens, usage.cached_tokens, usage.output_tokens), (700, 300, 50));
    assert_eq!(usage.context_window_tokens, Some(272_000));
    assert_eq!(usage.context_used_tokens, Some(4200));
    assert_eq!(usage.limits.len(), 2);
    assert_eq!(usage.limits[0].label, "5 hours");
    assert_eq!(usage.limits[0].used_fraction, 0.125);
    assert_eq!(usage.limits[0].resets_at, Some(100.0));
    assert_eq!(usage.limits[1].label, "7 days");
    assert_eq!(usage.limits[1].used_fraction, 1.0);
}

#[test]
fn a_log_without_a_token_count_has_no_answer() {
    assert_eq!(usage_from_log(r#"{"type":"event_msg","payload":{"type":"agent_message"}}"#), None);
}

#[test]
fn windows_are_labelled_as_a_person_says_them() {
    assert_eq!(label_for_minutes(60), "1 hour");
    assert_eq!(label_for_minutes(1440), "1 day");
    assert_eq!(label_for_minutes(43200), "30 days");
    assert_eq!(label_for_minutes(90), "90 minutes");
}

#[test]
fn the_log_is_found_in_its_dated_folder_by_thread_id() {
    let root = std::env::temp_dir().join(format!("peering-codex-log-{}", std::process::id()));
    let day = root.join("2026").join("11").join("01");
    fs::create_dir_all(&day).expect("folder");
    fs::write(day.join("rollout-2026-11-01-thread-9.jsonl"), LOG).expect("log");
    let mut known = LogLookup::default();
    let usage = read_usage(&root, "thread-9", &mut known);
    let _removed = fs::remove_dir_all(&root);
    assert_eq!(usage.map(|usage| usage.output_tokens), Some(50));
    assert!(known.path().is_some());
}

#[test]
fn only_listed_models_are_offered() {
    let cache = r#"{"models":[{"slug":"gpt-5","visibility":"list"},{"slug":"hidden","visibility":"hide"}]}"#;
    assert_eq!(visible_models(cache), vec!["gpt-5".to_owned()]);
    assert!(visible_models("{").is_empty());
}
