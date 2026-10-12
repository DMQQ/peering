use base64::engine::general_purpose::STANDARD;
use base64::Engine;

use super::*;

fn marker(duration_ms: u64, exit_status: i32, command: &str) -> Vec<u8> {
    format!("\x1b]9999;{duration_ms};{exit_status};{}\x07", STANDARD.encode(command)).into_bytes()
}

#[test]
fn a_complete_marker_decodes_command_duration_and_exit_status() {
    let finish = FinishDetector::default().receive(&marker(5_500, 0, "npm run build"));
    assert_eq!(finish, Some(Finish { command: Some("npm run build".to_owned()), duration: 5.5, exit_status: 0 }));
}

#[test]
fn prompt_text_around_the_marker_does_not_interfere() {
    let mut data = b"Build succeeded\r\n".to_vec();
    data.extend(marker(12_340, 1, "make test"));
    data.extend(b"$ ");
    let finish = FinishDetector::default().receive(&data).expect("the marker is found");
    assert_eq!(finish.command.as_deref(), Some("make test"));
    assert_eq!(finish.exit_status, 1);
}

#[test]
fn a_marker_split_across_reads_is_detected_only_once_complete() {
    let mut detector = FinishDetector::default();
    let whole = marker(8_000, 0, "sleep 8");
    let (first, second) = whole.split_at(whole.len() / 2);
    assert_eq!(detector.receive(first), None);
    assert_eq!(detector.receive(second).and_then(|finish| finish.command).as_deref(), Some("sleep 8"));
}

#[test]
fn the_same_marker_is_never_reported_twice() {
    let mut detector = FinishDetector::default();
    assert!(detector.receive(&marker(5_000, 0, "sleep 5")).is_some());
    assert_eq!(detector.receive(b"$ "), None);
}

#[test]
fn a_malformed_marker_is_ignored() {
    assert_eq!(FinishDetector::default().receive(b"\x1b]9999;not-a-number;0;not-base64\x07"), None);
}

#[test]
fn no_command_survives_when_the_payload_cannot_be_decoded() {
    let finish = FinishDetector::default().receive(b"\x1b]9999;5000;2;not-valid-base64!!!\x07");
    assert_eq!(finish.map(|finish| finish.command), Some(None));
}

#[test]
fn notification_durations_round_at_the_seconds_minutes_and_hours_boundaries() {
    assert_eq!(duration_suffix(4.49), " after 4s");
    assert_eq!(duration_suffix(4.5), " after 5s");
    assert_eq!(duration_suffix(59.49), " after 59s");
    assert_eq!(duration_suffix(59.5), " after 1m 0s");
    assert_eq!(duration_suffix(65.5), " after 1m 6s");
    assert_eq!(duration_suffix(3_599.49), " after 59m 59s");
    assert_eq!(duration_suffix(3_599.5), " after 1h 0m");
    assert_eq!(duration_suffix(3_665.0), " after 1h 1m");
}

#[test]
fn a_duration_that_is_not_a_sane_number_is_dropped_or_clamped() {
    for text in ["inf", "nan", "-5"] {
        let marker = format!("\x1b]9999;{text};0;\x07");
        assert_eq!(FinishDetector::default().receive(marker.as_bytes()), None);
    }
    let huge = FinishDetector::default().receive(b"\x1b]9999;1e30;0;\x07").map(|finish| finish.duration);
    assert_eq!(huge, Some(MAXIMUM_DURATION_SECONDS));
    assert_eq!(duration_suffix(f64::INFINITY), duration_suffix(1e30));
    assert_eq!(duration_suffix(f64::NAN), " after 0s");
    assert_eq!(duration_suffix(-3.0), " after 0s");
}
