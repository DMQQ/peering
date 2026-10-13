use super::*;

fn video_vector(name: &str) -> serde_json::Value {
    crate::vectors_dir::load("wire.json")[name].clone()
}

fn hex_field(value: &serde_json::Value, key: &str) -> Vec<u8> {
    hex::decode(value[key].as_str().unwrap()).unwrap()
}

fn sample_timestamp() -> VideoTimestamp {
    VideoTimestamp { value: 90_000, timescale: 90_000 }
}

fn config(parameter_sets: Vec<Vec<u8>>) -> VideoStreamConfig {
    VideoStreamConfig {
        source_id: "display-1".into(),
        codec: VideoCodec::H264,
        pixel_width: 1920,
        pixel_height: 1080,
        parameter_sets,
    }
}

#[test]
fn video_vector_decodes_to_its_documented_fields() {
    let vector = video_vector("videoFrame");
    let frame = EncodedVideoFrame::decode(&hex_field(&vector, "bytes")).unwrap();
    assert_eq!(
        frame,
        EncodedVideoFrame {
            is_keyframe: vector["keyframe"].as_bool().unwrap(),
            pixel_width: 1920,
            pixel_height: 1080,
            presentation_time: sample_timestamp(),
            data: hex_field(&vector, "data"),
        }
    );
}

#[test]
fn video_vector_encodes_to_the_same_bytes() {
    let vector = video_vector("videoFrame");
    let frame = EncodedVideoFrame::decode(&hex_field(&vector, "bytes")).unwrap();
    assert_eq!(frame.encode().unwrap(), hex_field(&vector, "bytes"));
}

#[test]
fn video_shared_error_vectors_map_to_their_variants() {
    for case in video_vector("videoFrameErrors").as_array().unwrap() {
        let result = EncodedVideoFrame::decode(&hex_field(case, "bytes"));
        let name = case["name"].as_str().unwrap();
        match case["error"].as_str().unwrap() {
            "lengthMismatch" => assert!(matches!(result, Err(VideoWireError::LengthMismatch { .. })), "{name}"),
            "truncatedHeader" => assert!(matches!(result, Err(VideoWireError::TruncatedHeader { .. })), "{name}"),
            other => panic!("unknown vector error {other}"),
        }
    }
}

#[test]
fn video_frame_round_trips_negative_timestamps_and_delta_flags() {
    let frame = EncodedVideoFrame {
        is_keyframe: false,
        pixel_width: u32::MAX,
        pixel_height: 0,
        presentation_time: VideoTimestamp { value: -5, timescale: -1 },
        data: vec![0, 0, 0, 1, 0x41],
    };
    assert_eq!(EncodedVideoFrame::decode(&frame.encode().unwrap()).unwrap(), frame);
}

#[test]
fn video_declared_length_past_the_end_is_rejected_without_overflow() {
    let mut bytes = vec![0u8; VIDEO_HEADER_SIZE];
    bytes[21..25].copy_from_slice(&u32::MAX.to_be_bytes());
    assert_eq!(
        EncodedVideoFrame::decode(&bytes),
        Err(VideoWireError::LengthMismatch { declared: u32::MAX as usize, actual: 0 })
    );
}

#[test]
fn audio_vector_decodes_to_its_documented_fields() {
    let vector = video_vector("audioFrame");
    let bytes = hex_field(&vector, "bytes");
    let frame = EncodedAudioFrame::decode(&bytes).unwrap();
    assert_eq!(frame.sample_count, 2);
    assert_eq!(frame.channel_count, 2);
    assert_eq!(frame.presentation_time, VideoTimestamp { value: 44_100, timescale: 44_100 });
    assert_eq!(frame.samples, bytes[AUDIO_HEADER_SIZE..]);
    assert_eq!(frame.encode(), bytes);
}

#[test]
fn audio_rejects_zero_samples_and_out_of_range_channels() {
    let frame = |sample_count, channel_count| {
        EncodedAudioFrame {
            sample_count,
            channel_count,
            presentation_time: sample_timestamp(),
            samples: vec![0; 4],
        }
        .encode()
    };
    assert_eq!(EncodedAudioFrame::decode(&frame(0, 1)), Err(AudioWireError::InvalidSampleCount(0)));
    assert_eq!(EncodedAudioFrame::decode(&frame(1, 0)), Err(AudioWireError::InvalidChannelCount(0)));
    assert_eq!(EncodedAudioFrame::decode(&frame(1, 33)), Err(AudioWireError::InvalidChannelCount(33)));
}

#[test]
fn audio_length_must_be_samples_times_channels_times_four() {
    let mut bytes = EncodedAudioFrame {
        sample_count: 2,
        channel_count: 2,
        presentation_time: sample_timestamp(),
        samples: vec![0; 16],
    }
    .encode();
    bytes.pop();
    assert_eq!(
        EncodedAudioFrame::decode(&bytes),
        Err(AudioWireError::LengthMismatch { declared: 16, actual: 15 })
    );
}

#[test]
fn audio_huge_counts_are_errors_not_panics() {
    let mut bytes = vec![0u8; AUDIO_HEADER_SIZE];
    bytes[0..4].copy_from_slice(&u32::MAX.to_be_bytes());
    bytes[4..8].copy_from_slice(&32u32.to_be_bytes());
    assert_eq!(
        EncodedAudioFrame::decode(&bytes),
        Err(AudioWireError::ByteCountOverflow { sample_count: u32::MAX, channel_count: 32 })
    );
    bytes[0..4].copy_from_slice(&1000u32.to_be_bytes());
    bytes[4..8].copy_from_slice(&1u32.to_be_bytes());
    assert_eq!(
        EncodedAudioFrame::decode(&bytes),
        Err(AudioWireError::LengthMismatch { declared: 4000, actual: 0 })
    );
}

#[test]
fn truncated_headers_report_what_was_present() {
    assert_eq!(
        EncodedVideoFrame::decode(&[1, 0, 0]),
        Err(VideoWireError::TruncatedHeader { have: 3, need: VIDEO_HEADER_SIZE })
    );
    assert_eq!(
        EncodedAudioFrame::decode(&[]),
        Err(AudioWireError::TruncatedHeader { have: 0, need: AUDIO_HEADER_SIZE })
    );
}

#[test]
fn a_zero_timescale_gives_zero_seconds() {
    assert_eq!(VideoTimestamp { value: 5, timescale: 0 }.seconds(), 0.0);
    assert_eq!(VideoTimestamp { value: 45_000, timescale: 90_000 }.seconds(), 0.5);
}

#[test]
fn the_first_description_is_sent() {
    let first = config(vec![vec![1], vec![2]]);
    assert_eq!(VideoStreamConfig::updated(None, first.clone()), Some(first));
}

#[test]
fn an_unchanged_description_is_not_sent_again() {
    let first = config(vec![vec![1], vec![2]]);
    assert_eq!(VideoStreamConfig::updated(Some(&first), first.clone()), None);
}

#[test]
fn a_changed_description_is_sent_even_when_only_the_source_differs() {
    let first = config(vec![vec![1]]);
    let other_source = VideoStreamConfig { source_id: "display-2".into(), ..first.clone() };
    assert_eq!(VideoStreamConfig::updated(Some(&first), other_source.clone()), Some(other_source));
}

#[test]
fn a_frame_without_parameter_sets_never_produces_a_config() {
    let first = config(vec![vec![1]]);
    assert_eq!(VideoStreamConfig::updated(Some(&first), config(Vec::new())), None);
    assert_eq!(VideoStreamConfig::updated(None, config(Vec::new())), None);
}

#[test]
fn config_json_uses_the_swift_keys_and_base64_parameter_sets() {
    let json = serde_json::to_value(config(vec![vec![1, 2]])).unwrap();
    assert_eq!(json["sourceID"], "display-1");
    assert_eq!(json["codec"], "h264");
    assert_eq!(json["pixelWidth"], 1920);
    assert_eq!(json["parameterSets"][0], "AQI=");
    let parsed: VideoStreamConfig = serde_json::from_value(json).unwrap();
    assert_eq!(parsed, config(vec![vec![1, 2]]));
}

#[test]
fn audio_config_json_uses_the_swift_keys() {
    let text = r#"{"codec":"pcmFloat32","sampleRate":48000.0,"channelCount":2}"#;
    let parsed: AudioStreamConfig = serde_json::from_str(text).unwrap();
    assert_eq!(parsed, AudioStreamConfig { codec: AudioCodec::PcmFloat32, sample_rate: 48_000.0, channel_count: 2 });
    assert_eq!(serde_json::to_string(&parsed).unwrap(), text);
}
