use super::*;
use peering_core::ports::encoder::EncodeError;
use peering_wire::quality::default_bitrate_bps;
use peering_wire::video::{VideoCodec, VideoStreamConfig};

fn candidate(hardware: bool, d3d11_aware: bool) -> CandidateInfo {
    CandidateInfo { hardware, d3d11_aware }
}

fn stream_config(sps: &[u8], pps: &[u8]) -> VideoStreamConfig {
    h264_config("screen", 1920, 1080, Some(sps.to_vec()), Some(pps.to_vec()))
}

#[test]
fn odd_sides_round_down_to_even() {
    let settings = EncoderSettings::new(1921, 1081, 60, 8_000_000).unwrap();
    assert_eq!((settings.width, settings.height), (1920, 1080));
}

#[test]
fn a_zero_bitrate_takes_the_default_for_the_size() {
    let settings = EncoderSettings::new(1920, 1080, 60, 0).unwrap();
    assert_eq!(settings.bitrate_bps, default_bitrate_bps(1920, 1080, 60));
}

#[test]
fn an_explicit_bitrate_is_kept() {
    let settings = EncoderSettings::new(1920, 1080, 60, 12_000_000).unwrap();
    assert_eq!(settings.bitrate_bps, 12_000_000);
}

#[test]
fn a_side_that_rounds_to_zero_is_rejected() {
    assert!(matches!(EncoderSettings::new(1, 1080, 60, 0), Err(EncodeError::Unsupported(_))));
}

#[test]
fn zero_frame_rate_is_rejected() {
    assert!(matches!(EncoderSettings::new(1920, 1080, 0, 0), Err(EncodeError::Unsupported(_))));
}

#[test]
fn the_keyframe_interval_is_two_seconds_of_frames() {
    assert_eq!(EncoderSettings::new(1920, 1080, 60, 0).unwrap().gop_size(), 120);
}

#[test]
fn hardware_candidates_come_before_software_ones() {
    let order = rank_candidates(&[candidate(false, true), candidate(true, false)]);
    assert_eq!(order, vec![1, 0]);
}

#[test]
fn within_a_class_the_d3d11_aware_candidate_comes_first() {
    let order = rank_candidates(&[candidate(true, false), candidate(true, true), candidate(false, true)]);
    assert_eq!(order, vec![1, 0, 2]);
}

#[test]
fn ties_keep_enumeration_order() {
    let order = rank_candidates(&[candidate(true, true), candidate(true, true)]);
    assert_eq!(order, vec![0, 1]);
}

#[test]
fn no_candidates_rank_to_nothing() {
    assert!(rank_candidates(&[]).is_empty());
}

#[test]
fn frame_time_is_in_hundred_nanoseconds_and_exact_at_sixty_fps() {
    assert_eq!(frame_time(0, 60), 0);
    assert_eq!(frame_time(60, 60), HUNDRED_NANOSECONDS_PER_SECOND);
    assert_eq!(frame_time(1, 60), 166_666);
}

#[test]
fn frame_duration_matches_the_frame_rate() {
    assert_eq!(frame_duration(60), 166_666);
    assert_eq!(frame_duration(0), HUNDRED_NANOSECONDS_PER_SECOND);
}

#[test]
fn video_timestamp_keeps_the_hundred_nanosecond_scale() {
    let stamp = video_timestamp(12_345);
    assert_eq!((stamp.value, stamp.timescale), (12_345, 10_000_000));
}

#[test]
fn a_config_needs_both_parameter_sets() {
    let only_sps = h264_config("screen", 1920, 1080, Some(vec![0x67]), None);
    assert!(only_sps.parameter_sets.is_empty());
    assert_eq!(only_sps.codec, VideoCodec::H264);
}

#[test]
fn the_first_config_is_emitted_and_an_identical_one_is_not() {
    let mut tracker = ConfigTracker::default();
    assert!(tracker.observe(stream_config(&[0x67, 1], &[0x68, 1])).is_some());
    assert!(tracker.observe(stream_config(&[0x67, 1], &[0x68, 1])).is_none());
}

#[test]
fn a_changed_parameter_set_is_emitted_again() {
    let mut tracker = ConfigTracker::default();
    tracker.observe(stream_config(&[0x67, 1], &[0x68, 1]));
    let changed = tracker.observe(stream_config(&[0x67, 2], &[0x68, 1]));
    assert_eq!(changed.map(|config| config.parameter_sets[0].clone()), Some(vec![0x67, 2]));
}

#[test]
fn a_frame_without_parameter_sets_never_emits_a_config() {
    let mut tracker = ConfigTracker::default();
    assert!(tracker.observe(h264_config("screen", 1920, 1080, None, None)).is_none());
}
