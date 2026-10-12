use super::*;
use crate::fakes::capture::FakeCapture;
use crate::fakes::clock::FakeClock;
use crate::fakes::encoder::FakeEncoder;
use crate::ports::capture::DisplayInfo;
use crate::ports::clock::Clock;

fn display(id: u32, is_primary: bool) -> DisplayInfo {
    DisplayInfo {
        id,
        name: format!("Display {id}"),
        pixel_width: 1920,
        pixel_height: 1080,
        origin_x: 0,
        origin_y: 0,
        scale: 1.0,
        is_primary,
    }
}

fn coordinator() -> VideoCoordinator<FakeCapture, FakeEncoder> {
    let capture = FakeCapture::new(vec![display(1, true), display(2, false)]);
    VideoCoordinator::new(capture, FakeEncoder::default())
}

fn display_source(id: u32) -> CaptureSource {
    CaptureSource::Display { id }
}

fn raw(sequence: u64) -> RawFrame {
    RawFrame { width: 1920, height: 1080, sequence }
}

fn push(coordinator: &mut VideoCoordinator<FakeCapture, FakeEncoder>, sequences: &[u64]) {
    for sequence in sequences {
        coordinator.capture.push_frame(raw(*sequence));
    }
}

fn frames(outputs: &[VideoOutput]) -> Vec<&EncodedVideoFrame> {
    outputs
        .iter()
        .filter_map(|output| match output {
            VideoOutput::Frame(frame) => Some(frame),
            VideoOutput::Config(_) => None,
        })
        .collect()
}

fn configs(outputs: &[VideoOutput]) -> Vec<&VideoStreamConfig> {
    outputs
        .iter()
        .filter_map(|output| match output {
            VideoOutput::Config(config) => Some(config),
            VideoOutput::Frame(_) => None,
        })
        .collect()
}

fn sequence_of(frame: &EncodedVideoFrame) -> u64 {
    u64::from_be_bytes(frame.data.clone().try_into().unwrap())
}

#[test]
fn a_client_attached_to_a_running_capture_gets_a_config_and_a_keyframe() {
    let mut coordinator = coordinator();
    coordinator.set_source(display_source(1), 0.0).unwrap();
    coordinator.attach("phone");
    push(&mut coordinator, &[1]);
    let outputs = coordinator.pump(0.1).unwrap();
    assert_eq!(configs(&outputs).len(), 1);
    assert_eq!(configs(&outputs)[0].source_id, "display:1");
    assert!(frames(&outputs)[0].is_keyframe);
}

#[test]
fn nothing_is_encoded_while_no_client_is_attached() {
    let mut coordinator = coordinator();
    coordinator.set_source(display_source(1), 0.0).unwrap();
    push(&mut coordinator, &[1, 2]);
    assert!(coordinator.pump(0.1).unwrap().is_empty());
    assert!(coordinator.encoder.encode_calls().is_empty());
}

#[test]
fn a_second_client_forces_a_keyframe_and_repeats_the_config() {
    let mut coordinator = coordinator();
    coordinator.set_source(display_source(1), 0.0).unwrap();
    coordinator.attach("first");
    push(&mut coordinator, &[1, 2]);
    coordinator.pump(0.1).unwrap();
    coordinator.attach("second");
    push(&mut coordinator, &[3]);
    let outputs = coordinator.pump(0.2).unwrap();
    assert_eq!(configs(&outputs).len(), 1);
    assert!(frames(&outputs)[0].is_keyframe);
    assert_eq!(coordinator.encoder.encode_calls().last(), Some(&(3, true)));
}

#[test]
fn switching_source_emits_exactly_one_config_with_the_new_source_id() {
    let mut coordinator = coordinator();
    coordinator.set_source(display_source(1), 0.0).unwrap();
    coordinator.attach("phone");
    push(&mut coordinator, &[1]);
    coordinator.pump(0.1).unwrap();

    coordinator.set_source(display_source(2), 0.2).unwrap();
    push(&mut coordinator, &[2, 3]);
    let switched = coordinator.pump(0.3).unwrap();
    assert_eq!(configs(&switched).len(), 1);
    assert_eq!(configs(&switched)[0].source_id, "display:2");

    push(&mut coordinator, &[4]);
    assert!(configs(&coordinator.pump(0.4).unwrap()).is_empty());
}

#[test]
fn selecting_the_running_source_again_changes_nothing() {
    let mut coordinator = coordinator();
    coordinator.set_source(display_source(1), 0.0).unwrap();
    coordinator.set_source(display_source(1), 1.0).unwrap();
    assert_eq!(coordinator.encoder.configure_calls().len(), 1);
    assert_eq!(coordinator.running_source(), Some(&display_source(1)));
}

#[test]
fn an_unknown_display_is_refused_and_leaves_nothing_running() {
    let mut coordinator = coordinator();
    let error = coordinator.set_source(display_source(9), 0.0).unwrap_err();
    assert!(matches!(error, CoordinatorError::Capture(CaptureError::DisplayNotFound(9))));
    assert_eq!(coordinator.running_source(), None);
    assert_eq!(coordinator.chosen_source(), None);
}

#[test]
fn a_window_source_is_refused_because_only_displays_are_captured() {
    let mut coordinator = coordinator();
    let error = coordinator.set_source(CaptureSource::Window { id: 7 }, 0.0).unwrap_err();
    assert!(matches!(error, CoordinatorError::UnsupportedSource(ref text) if text == "window:7"));
}

#[test]
fn the_requested_bitrate_is_clamped_and_applied_to_the_encoder() {
    let mut coordinator = coordinator();
    coordinator.set_source(display_source(1), 0.0).unwrap();
    coordinator.set_quality(250_000);
    assert_eq!(coordinator.encoder.bitrate_calls().last(), Some(&100_000_000));
}

#[test]
fn a_non_positive_bitrate_request_is_ignored() {
    let mut coordinator = coordinator();
    coordinator.set_source(display_source(1), 0.0).unwrap();
    let before = coordinator.encoder.bitrate_calls().len();
    coordinator.set_quality(0);
    assert_eq!(coordinator.encoder.bitrate_calls().len(), before);
}

#[test]
fn the_bitrate_ceiling_caps_a_larger_request() {
    let mut coordinator = coordinator();
    coordinator.set_source(display_source(1), 0.0).unwrap();
    coordinator.set_quality(8_000);
    coordinator.set_bitrate_ceiling(Some(2_000));
    assert_eq!(coordinator.encoder.bitrate_bps(), 2_000_000);
    coordinator.set_bitrate_ceiling(None);
    assert_eq!(coordinator.encoder.bitrate_bps(), 8_000_000);
}

#[test]
fn pausing_drops_frames_without_encoding_them() {
    let mut coordinator = coordinator();
    coordinator.set_source(display_source(1), 0.0).unwrap();
    coordinator.attach("phone");
    coordinator.set_video_enabled(false);
    push(&mut coordinator, &[1, 2]);
    assert!(coordinator.pump(0.1).unwrap().is_empty());
    assert!(coordinator.encoder.encode_calls().is_empty());
}

#[test]
fn the_first_frame_after_resuming_is_a_keyframe_with_its_config() {
    let mut coordinator = coordinator();
    coordinator.set_source(display_source(1), 0.0).unwrap();
    coordinator.attach("phone");
    push(&mut coordinator, &[1, 2]);
    coordinator.pump(0.1).unwrap();
    coordinator.set_video_enabled(false);
    push(&mut coordinator, &[3]);
    coordinator.pump(0.2).unwrap();
    coordinator.set_video_enabled(true);
    push(&mut coordinator, &[4]);
    let outputs = coordinator.pump(0.3).unwrap();
    assert_eq!(configs(&outputs).len(), 1);
    assert!(frames(&outputs)[0].is_keyframe);
    assert_eq!(coordinator.encoder.encode_calls().last(), Some(&(4, true)));
}

#[test]
fn a_burst_keeps_only_the_newest_delta() {
    let mut coordinator = coordinator();
    coordinator.set_source(display_source(1), 0.0).unwrap();
    coordinator.attach("phone");
    push(&mut coordinator, &[1]);
    coordinator.pump(0.1).unwrap();
    push(&mut coordinator, &[2, 3, 4]);
    let outputs = coordinator.pump(0.2).unwrap();
    let delivered = frames(&outputs);
    assert_eq!(delivered.len(), 1);
    assert_eq!(sequence_of(delivered[0]), 4);
    assert_eq!(coordinator.dropped_frames(), 2);
}

#[test]
fn a_waiting_keyframe_survives_a_burst_of_deltas() {
    let mut coordinator = coordinator();
    coordinator.set_source(display_source(1), 0.0).unwrap();
    coordinator.attach("phone");
    push(&mut coordinator, &[1, 2, 3]);
    let outputs = coordinator.pump(0.1).unwrap();
    let delivered = frames(&outputs);
    assert_eq!(delivered.len(), 1);
    assert!(delivered[0].is_keyframe);
    assert_eq!(sequence_of(delivered[0]), 1);
}

#[test]
fn the_watchdog_fires_only_when_no_frame_has_ever_arrived() {
    let clock = FakeClock::new(0.0, 0);
    let mut coordinator = coordinator();
    coordinator.set_source(display_source(1), clock.now_seconds()).unwrap();
    clock.advance(4.9);
    assert!(!coordinator.watchdog_expired(clock.now_seconds()));
    clock.advance(0.1);
    assert!(coordinator.watchdog_expired(clock.now_seconds()));
}

#[test]
fn a_still_screen_after_a_first_frame_does_not_trip_the_watchdog() {
    let mut coordinator = coordinator();
    coordinator.set_source(display_source(1), 0.0).unwrap();
    push(&mut coordinator, &[1]);
    coordinator.pump(0.5).unwrap();
    assert!(!coordinator.watchdog_expired(60.0));
}

#[test]
fn leaving_with_no_clients_forgets_the_chosen_source_but_keeps_capturing() {
    let mut coordinator = coordinator();
    coordinator.attach("phone");
    coordinator.set_source(display_source(2), 0.0).unwrap();
    coordinator.detach("phone");
    coordinator.forget_chosen_source_if_idle();
    assert_eq!(coordinator.chosen_source(), None);
    assert_eq!(coordinator.running_source(), Some(&display_source(2)));
}

#[test]
fn the_chosen_source_is_kept_while_a_client_is_still_attached() {
    let mut coordinator = coordinator();
    coordinator.attach("phone");
    coordinator.attach("tablet");
    coordinator.set_source(display_source(2), 0.0).unwrap();
    coordinator.detach("phone");
    coordinator.forget_chosen_source_if_idle();
    assert_eq!(coordinator.chosen_source(), Some(&display_source(2)));
}

fn encoded_passes(coordinator: &mut VideoCoordinator<FakeCapture, FakeEncoder>, times: &[f64]) -> usize {
    let mut encoded = 0;
    for (sequence, now) in times.iter().enumerate() {
        push(coordinator, &[sequence as u64 + 1]);
        encoded += frames(&coordinator.pump(*now).expect("the pump runs")).len();
    }
    encoded
}

#[test]
fn at_the_default_rate_every_pass_that_captures_a_frame_encodes_it() {
    let mut coordinator = coordinator();
    coordinator.attach("phone");
    coordinator.set_source(display_source(1), 0.0).expect("the source starts");
    assert_eq!(encoded_passes(&mut coordinator, &[0.0, 0.0166, 0.0333, 0.05, 0.0666]), 5);
}

#[test]
fn a_lower_frame_rate_encodes_only_the_passes_that_fall_due() {
    let mut coordinator = coordinator();
    coordinator.attach("phone");
    coordinator.set_source(display_source(1), 0.0).expect("the source starts");
    coordinator.set_frame_rate(15);
    assert_eq!(encoded_passes(&mut coordinator, &[0.0, 0.0166, 0.0333, 0.05, 0.0666]), 2);
}

#[test]
fn a_frame_rate_change_reconfigures_the_encoder_and_asks_for_a_keyframe() {
    let mut coordinator = coordinator();
    coordinator.attach("phone");
    coordinator.set_source(display_source(1), 0.0).expect("the source starts");
    coordinator.pump(0.0).expect("the pump runs");
    coordinator.set_frame_rate(30);
    push(&mut coordinator, &[2]);
    let outputs = coordinator.pump(0.1).expect("the pump runs");
    let last_configure = coordinator.encoder.configure_calls().last().copied().expect("configured again");
    assert_eq!(last_configure.2, 30);
    assert!(frames(&outputs).first().is_some_and(|frame| frame.is_keyframe));
}

#[test]
fn a_requested_frame_rate_is_snapped_to_an_allowed_one() {
    let mut coordinator = coordinator();
    coordinator.set_frame_rate(24);
    assert_eq!(coordinator.frame_rate(), 30);
    coordinator.set_frame_rate(120);
    assert_eq!(coordinator.frame_rate(), 60);
}

#[test]
fn the_time_of_the_last_encoded_frame_is_recorded() {
    let mut coordinator = coordinator();
    coordinator.set_source(display_source(1), 0.0).unwrap();
    coordinator.attach("phone");
    push(&mut coordinator, &[1]);
    coordinator.pump(3.5).unwrap();
    assert_eq!(coordinator.last_frame_produced_at(), Some(3.5));
}
