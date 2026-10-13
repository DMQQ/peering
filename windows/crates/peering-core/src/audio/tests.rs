use peering_wire::video::EncodedAudioFrame;

use super::*;

fn packet(rate: u32, channels: u32, frames: usize, value: f32) -> CapturedAudio {
    CapturedAudio { sample_rate: rate, channels, samples: vec![value; frames * channels as usize] }
}

fn first_sample(frame: &EncodedAudioFrame) -> f32 {
    f32::from_le_bytes([frame.samples[0], frame.samples[1], frame.samples[2], frame.samples[3]])
}

#[test]
fn the_config_is_what_the_mac_announces() {
    let config = output_config();
    assert_eq!(config.sample_rate, 48_000.0);
    assert_eq!(config.channel_count, 2);
}

#[test]
fn a_stereo_packet_at_48k_is_cut_into_frames_of_960_samples() {
    let mut conditioner = AudioConditioner::new();
    let frames = conditioner.push(&packet(48_000, 2, 2000, 0.5));
    assert_eq!(frames.len(), 2);
    for frame in &frames {
        assert_eq!((frame.sample_count, frame.channel_count), (960, 2));
        assert_eq!(frame.samples.len(), 960 * 2 * 4);
        assert_eq!(first_sample(frame), 0.5);
    }
    assert_eq!(conditioner.push(&packet(48_000, 2, 1000, 0.5)).len(), 1, "the 80 left over complete a third frame");
}

#[test]
fn frames_encode_to_a_payload_the_wire_decodes() {
    let mut conditioner = AudioConditioner::new();
    let frame = conditioner.push(&packet(48_000, 2, 960, -0.25)).remove(0);
    let decoded = EncodedAudioFrame::decode(&frame.encode()).expect("a valid audio payload");
    assert_eq!(decoded, frame);
}

#[test]
fn samples_are_little_endian_floats() {
    let mut conditioner = AudioConditioner::new();
    let frame = conditioner.push(&packet(48_000, 2, 960, 1.0)).remove(0);
    assert_eq!(&frame.samples[..4], &[0x00, 0x00, 0x80, 0x3F]);
}

#[test]
fn presentation_times_count_samples_at_48k() {
    let mut conditioner = AudioConditioner::new();
    let frames = conditioner.push(&packet(48_000, 2, 2880, 0.1));
    let times: Vec<i64> = frames.iter().map(|frame| frame.presentation_time.value).collect();
    assert_eq!(times, vec![0, 960, 1920]);
    assert!(frames.iter().all(|frame| frame.presentation_time.timescale == 48_000));
}

#[test]
fn mono_plays_on_both_sides_and_wide_layouts_keep_the_front_pair() {
    assert_eq!(to_stereo(&[0.1, 0.2], 1), vec![0.1, 0.1, 0.2, 0.2]);
    assert_eq!(to_stereo(&[1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0], 4), vec![1.0, 2.0, 5.0, 6.0]);
    assert_eq!(to_stereo(&[1.0, 2.0, 3.0], 2), vec![1.0, 2.0], "a torn last frame is dropped");
    assert!(to_stereo(&[1.0], 0).is_empty());
}

#[test]
fn a_44_1k_stream_comes_out_at_48k_length() {
    let mut conditioner = AudioConditioner::new();
    let mut produced = 0;
    for _ in 0..100 {
        produced += conditioner.push(&packet(44_100, 2, 441, 0.3)).len();
    }
    // 100 packets of 10 ms are one second, which is 50 frames of 20 ms (one may still be waiting).
    assert!((49..=50).contains(&produced), "got {produced}");
}

#[test]
fn resampling_keeps_a_constant_level_across_packet_boundaries() {
    let mut resampler = StereoResampler::new(44_100, 48_000);
    let mut all = Vec::new();
    for _ in 0..10 {
        all.extend(resampler.process(&vec![0.5; 441 * 2]));
    }
    assert!(all.iter().all(|sample| (*sample - 0.5).abs() < 1e-6));
    assert!((all.len() as i64 - 9600).abs() <= 4, "got {}", all.len());
}

#[test]
fn resampling_a_ramp_stays_monotonic_without_jumps() {
    let mut resampler = StereoResampler::new(24_000, 48_000);
    let ramp: Vec<f32> = (0..200).flat_map(|n| [n as f32, n as f32]).collect();
    let mut all = resampler.process(&ramp[..200]);
    all.extend(resampler.process(&ramp[200..]));
    let left: Vec<f32> = all.iter().step_by(2).copied().collect();
    assert!(left.windows(2).all(|pair| pair[1] >= pair[0] && pair[1] - pair[0] <= 0.51), "{left:?}");
}

#[test]
fn equal_rates_pass_through_untouched() {
    let mut resampler = StereoResampler::new(48_000, 48_000);
    assert_eq!(resampler.process(&[0.1, 0.2, 0.3, 0.4]), vec![0.1, 0.2, 0.3, 0.4]);
}

#[test]
fn a_change_of_rate_starts_a_new_resampler_and_keeps_the_frame_clock() {
    let mut conditioner = AudioConditioner::new();
    conditioner.push(&packet(48_000, 2, 960, 0.1));
    let frames = conditioner.push(&packet(44_100, 2, 4410, 0.1));
    assert!(!frames.is_empty());
    assert_eq!(frames[0].presentation_time.value, 960);
}

#[test]
fn flush_pads_the_tail_with_silence() {
    let mut conditioner = AudioConditioner::new();
    assert!(conditioner.push(&packet(48_000, 2, 100, 0.5)).is_empty());
    let frame = conditioner.flush().expect("a tail is waiting");
    assert_eq!(frame.sample_count, 960);
    assert_eq!(first_sample(&frame), 0.5);
    let last = f32::from_le_bytes(frame.samples[frame.samples.len() - 4..].try_into().unwrap());
    assert_eq!(last, 0.0);
    assert!(conditioner.flush().is_none());
}

#[test]
fn reset_drops_what_was_waiting() {
    let mut conditioner = AudioConditioner::new();
    conditioner.push(&packet(48_000, 2, 100, 0.5));
    conditioner.reset();
    assert!(conditioner.flush().is_none());
}

#[test]
fn values_a_driver_should_never_produce_are_cleaned() {
    let mut conditioner = AudioConditioner::new();
    let mut loud = packet(48_000, 2, 960, 0.0);
    loud.samples[0] = f32::NAN;
    loud.samples[1] = 1.0e9;
    let frame = conditioner.push(&loud).remove(0);
    assert_eq!(first_sample(&frame), 0.0);
    assert_eq!(f32::from_le_bytes(frame.samples[4..8].try_into().unwrap()), 4.0);
}

#[test]
fn an_empty_or_unlabelled_packet_makes_nothing() {
    let mut conditioner = AudioConditioner::new();
    assert!(conditioner.push(&packet(48_000, 2, 0, 0.0)).is_empty());
    assert!(conditioner.push(&packet(0, 2, 960, 0.0)).is_empty());
}

#[test]
fn the_config_is_owed_once_and_again_when_the_route_changes() {
    let mut delivery = AudioDelivery::default();
    assert!(delivery.config_due(false));
    assert!(!delivery.config_due(false));
    assert!(delivery.config_due(true), "the video connection opened");
    assert!(!delivery.config_due(true));
    delivery.pause();
    assert!(delivery.config_due(true), "after a pause the player is restarted");
}
