use super::*;
use peering_wire::video::VideoWireError;

#[test]
fn capture_failures_rebuild_the_pipeline_and_encoder_failures_the_encoder() {
    let lost = CoordinatorError::Capture(CaptureError::Failed("device removed".to_owned()));
    let gone = CoordinatorError::Capture(CaptureError::DisplayNotFound(3));
    let broken = CoordinatorError::Encode(EncodeError::Failed("transform".to_owned()));
    assert_eq!(remedy_for(&lost), Remedy::Pipeline);
    assert_eq!(remedy_for(&gone), Remedy::Pipeline);
    assert_eq!(remedy_for(&broken), Remedy::Encoder);
    assert_eq!(remedy_for(&CoordinatorError::Encode(EncodeError::NotConfigured)), Remedy::Encoder);
}

#[test]
fn a_setting_the_encoder_cannot_do_is_not_retried() {
    let unsupported = CoordinatorError::Encode(EncodeError::Unsupported("8k".to_owned()));
    assert_eq!(remedy_for(&unsupported), Remedy::Unrecoverable);
    assert_eq!(remedy_for(&CoordinatorError::UnsupportedSource("window".to_owned())), Remedy::Unrecoverable);
}

#[test]
fn a_wire_error_asks_only_for_a_resync() {
    let wire = CoordinatorError::Wire(VideoWireError::FieldTooLarge(1));
    assert_eq!(remedy_for(&wire), Remedy::Resync);
}

#[test]
fn retry_delays_grow_and_stop_at_fifteen_seconds() {
    let delays: Vec<f64> = (1..=8).map(retry_delay_seconds).collect();
    assert_eq!(delays, vec![0.5, 1.0, 2.0, 4.0, 8.0, 15.0, 15.0, 15.0]);
    assert_eq!(retry_delay_seconds(0), 0.5);
}

#[test]
fn a_failure_blocks_the_pump_until_the_backoff_runs_out() {
    let mut recovery = Recovery::default();
    recovery.failed(Remedy::Pipeline, 10.0);
    assert!(recovery.waiting(10.4));
    assert_eq!(recovery.due(10.4), None);
    assert!(!recovery.waiting(10.5));
    assert_eq!(recovery.due(10.5), Some(Remedy::Pipeline));
}

#[test]
fn backoff_keeps_growing_when_a_rebuild_succeeds_but_nothing_is_produced() {
    let mut recovery = Recovery::default();
    recovery.failed(Remedy::Pipeline, 0.0);
    recovery.rebuilt(0.5);
    recovery.failed(Remedy::Pipeline, 0.6);
    assert!(recovery.waiting(1.5));
    assert_eq!(recovery.due(1.6), Some(Remedy::Pipeline));
    assert_eq!(recovery.failures(), 2);
}

#[test]
fn produced_output_clears_the_failure_count() {
    let mut recovery = Recovery::default();
    recovery.failed(Remedy::Pipeline, 0.0);
    recovery.failed(Remedy::Pipeline, 1.0);
    recovery.produced_output();
    assert_eq!(recovery.failures(), 0);
    recovery.failed(Remedy::Pipeline, 5.0);
    assert!(recovery.waiting(5.4));
    assert!(!recovery.waiting(5.5));
}

#[test]
fn an_encoder_that_keeps_failing_widens_to_the_whole_pipeline() {
    let mut recovery = Recovery::default();
    recovery.failed(Remedy::Encoder, 0.0);
    assert_eq!(recovery.due(100.0), Some(Remedy::Encoder));
    recovery.failed(Remedy::Encoder, 1.0);
    assert_eq!(recovery.due(100.0), Some(Remedy::Encoder));
    recovery.failed(Remedy::Encoder, 2.0);
    assert_eq!(recovery.due(100.0), Some(Remedy::Pipeline));
}

#[test]
fn an_unrecoverable_failure_waits_the_longest_before_one_more_try() {
    let mut recovery = Recovery::default();
    recovery.failed(Remedy::Unrecoverable, 0.0);
    assert!(recovery.waiting(14.9));
    assert_eq!(recovery.due(15.0), Some(Remedy::Unrecoverable));
}

#[test]
fn the_client_is_told_once_after_the_second_failure_in_a_row() {
    let mut recovery = Recovery::default();
    recovery.failed(Remedy::Pipeline, 0.0);
    assert!(!recovery.take_report());
    recovery.failed(Remedy::Pipeline, 1.0);
    assert!(recovery.take_report());
    assert!(!recovery.take_report());
    recovery.failed(Remedy::Pipeline, 2.0);
    assert!(!recovery.take_report());
    recovery.produced_output();
    recovery.failed(Remedy::Pipeline, 9.0);
    recovery.failed(Remedy::Pipeline, 10.0);
    assert!(recovery.take_report());
}

#[test]
fn a_capture_that_reports_itself_failed_is_counted_once_while_it_waits() {
    let mut recovery = Recovery::default();
    recovery.capture_failed(0.0);
    recovery.capture_failed(0.1);
    recovery.capture_failed(0.2);
    assert_eq!(recovery.failures(), 1);
}

#[test]
fn a_capture_that_goes_quiet_stalls_after_thirty_seconds() {
    let mut recovery = Recovery::default();
    recovery.frame_seen(100.0);
    assert!(!recovery.stalled(129.9));
    assert!(recovery.stalled(130.0));
}

#[test]
fn a_stall_is_not_declared_while_a_recovery_is_waiting() {
    let mut recovery = Recovery::default();
    recovery.frame_seen(0.0);
    recovery.failed(Remedy::Pipeline, 40.0);
    assert!(!recovery.stalled(100.0));
}

#[test]
fn idle_time_does_not_count_towards_a_stall() {
    let mut recovery = Recovery::default();
    recovery.frame_seen(0.0);
    recovery.idle(50.0);
    assert!(!recovery.stalled(79.0));
    assert!(recovery.stalled(80.0));
}

#[test]
fn probes_that_only_find_a_still_screen_wait_longer_each_time() {
    let mut recovery = Recovery::default();
    recovery.frame_seen(0.0);
    recovery.stall_probe_started(30.0);
    recovery.rebuilt(30.0);
    recovery.frame_seen(30.5);
    assert!(!recovery.stalled(90.0));
    assert!(recovery.stalled(90.5));
    recovery.stall_probe_started(90.5);
    recovery.rebuilt(90.5);
    recovery.frame_seen(91.0);
    assert!(!recovery.stalled(210.5));
    assert!(recovery.stalled(211.0));
}

#[test]
fn a_frame_well_after_a_restart_resets_the_probe_interval() {
    let mut recovery = Recovery::default();
    recovery.frame_seen(0.0);
    recovery.stall_probe_started(30.0);
    recovery.rebuilt(30.0);
    recovery.frame_seen(30.5);
    recovery.frame_seen(45.0);
    assert!(!recovery.stalled(74.9));
    assert!(recovery.stalled(75.0));
}

#[test]
fn the_stall_window_doubles_and_caps_at_five_minutes() {
    assert_eq!(stall_window_seconds(0), 30.0);
    assert_eq!(stall_window_seconds(1), 60.0);
    assert_eq!(stall_window_seconds(3), 240.0);
    assert_eq!(stall_window_seconds(4), 300.0);
    assert_eq!(stall_window_seconds(40), 300.0);
}

#[test]
fn a_repeating_message_is_let_through_once_per_interval_with_the_count_held_back() {
    let mut gate = LogGate::default();
    assert_eq!(gate.allow(0.0), Some(0));
    assert_eq!(gate.allow(1.0), None);
    assert_eq!(gate.allow(9.9), None);
    assert_eq!(gate.allow(10.0), Some(2));
    assert_eq!(gate.allow(10.1), None);
}
