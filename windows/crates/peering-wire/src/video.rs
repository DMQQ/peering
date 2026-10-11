//! Video and audio frame wire format. See docs/protocol/video.md sections 1 and 5; Swift reference is VideoWire.swift.

use crate::swift_enum::base64_list;
use serde::{Deserialize, Serialize};
use thiserror::Error;

pub const VIDEO_HEADER_SIZE: usize = 25;
pub const AUDIO_HEADER_SIZE: usize = 20;
const KEYFRAME_FLAG: u8 = 1;
const MAX_AUDIO_CHANNELS: u32 = 32;
const FLOAT32_BYTES: u32 = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum VideoCodec {
    #[serde(rename = "h264")]
    H264,
    #[serde(rename = "hevc")]
    Hevc,
}

/// Sent when the description changes, never per frame. `parameter_sets` is SPS then PPS for H.264,
/// VPS, SPS, PPS for HEVC.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoStreamConfig {
    #[serde(rename = "sourceID")]
    pub source_id: String,
    pub codec: VideoCodec,
    pub pixel_width: u32,
    pub pixel_height: u32,
    #[serde(with = "base64_list")]
    pub parameter_sets: Vec<Vec<u8>>,
}

impl VideoStreamConfig {
    /// `None` when the candidate carries no parameter sets (a delta frame's description is empty, not a
    /// reset) or when it equals the description already sent.
    pub fn updated(previous: Option<&VideoStreamConfig>, candidate: VideoStreamConfig) -> Option<VideoStreamConfig> {
        if candidate.parameter_sets.is_empty() || previous == Some(&candidate) {
            return None;
        }
        Some(candidate)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VideoTimestamp {
    pub value: i64,
    pub timescale: i32,
}

impl VideoTimestamp {
    /// A zero timescale arrives off the network, so it reads as zero rather than dividing by it.
    pub fn seconds(self) -> f64 {
        if self.timescale == 0 {
            0.0
        } else {
            self.value as f64 / f64::from(self.timescale)
        }
    }
}

/// `data` is AVCC: each NAL unit prefixed by its 4 byte big endian length. Parameter sets are not in it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodedVideoFrame {
    pub is_keyframe: bool,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub presentation_time: VideoTimestamp,
    pub data: Vec<u8>,
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum VideoWireError {
    #[error("video header truncated: have {have} bytes, need {need}")]
    TruncatedHeader { have: usize, need: usize },
    #[error("video frame declares {declared} data bytes but carries {actual}")]
    LengthMismatch { declared: usize, actual: usize },
    #[error("video data of {0} bytes does not fit the 32 bit length field")]
    FieldTooLarge(usize),
}

impl EncodedVideoFrame {
    pub fn encode(&self) -> Result<Vec<u8>, VideoWireError> {
        let length = u32::try_from(self.data.len()).map_err(|_| VideoWireError::FieldTooLarge(self.data.len()))?;
        let mut out = Vec::with_capacity(VIDEO_HEADER_SIZE + self.data.len());
        out.push(if self.is_keyframe { KEYFRAME_FLAG } else { 0 });
        out.extend_from_slice(&self.pixel_width.to_be_bytes());
        out.extend_from_slice(&self.pixel_height.to_be_bytes());
        out.extend_from_slice(&self.presentation_time.value.to_be_bytes());
        out.extend_from_slice(&self.presentation_time.timescale.to_be_bytes());
        out.extend_from_slice(&length.to_be_bytes());
        out.extend_from_slice(&self.data);
        Ok(out)
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, VideoWireError> {
        let mut reader = Reader::new(bytes, VIDEO_HEADER_SIZE);
        let flags = reader.take::<1>()?[0];
        let pixel_width = u32::from_be_bytes(reader.take()?);
        let pixel_height = u32::from_be_bytes(reader.take()?);
        let value = i64::from_be_bytes(reader.take()?);
        let timescale = i32::from_be_bytes(reader.take()?);
        let declared = u32::from_be_bytes(reader.take()?) as usize;
        let data = reader.rest();
        if declared != data.len() {
            return Err(VideoWireError::LengthMismatch { declared, actual: data.len() });
        }
        Ok(Self {
            is_keyframe: flags & KEYFRAME_FLAG != 0,
            pixel_width,
            pixel_height,
            presentation_time: VideoTimestamp { value, timescale },
            data: data.to_vec(),
        })
    }
}

/// Interleaved samples, `sample_count` frames of `channel_count` values each. Float32 in the samples is
/// treated as little endian (every Mac is), which is not stated in the Swift source.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodedAudioFrame {
    pub sample_count: u32,
    pub channel_count: u32,
    pub presentation_time: VideoTimestamp,
    pub samples: Vec<u8>,
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum AudioWireError {
    #[error("audio header truncated: have {have} bytes, need {need}")]
    TruncatedHeader { have: usize, need: usize },
    #[error("audio frame sample count {0} must be at least 1")]
    InvalidSampleCount(u32),
    #[error("audio frame channel count {0} must be between 1 and 32")]
    InvalidChannelCount(u32),
    #[error("audio frame of {sample_count} samples by {channel_count} channels overflows the length check")]
    ByteCountOverflow { sample_count: u32, channel_count: u32 },
    #[error("audio frame expects {declared} sample bytes but carries {actual}")]
    LengthMismatch { declared: usize, actual: usize },
}

impl EncodedAudioFrame {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(AUDIO_HEADER_SIZE + self.samples.len());
        out.extend_from_slice(&self.sample_count.to_be_bytes());
        out.extend_from_slice(&self.channel_count.to_be_bytes());
        out.extend_from_slice(&self.presentation_time.value.to_be_bytes());
        out.extend_from_slice(&self.presentation_time.timescale.to_be_bytes());
        out.extend_from_slice(&self.samples);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, AudioWireError> {
        let mut reader = Reader::new(bytes, AUDIO_HEADER_SIZE);
        let sample_count = u32::from_be_bytes(reader.take()?);
        let channel_count = u32::from_be_bytes(reader.take()?);
        let value = i64::from_be_bytes(reader.take()?);
        let timescale = i32::from_be_bytes(reader.take()?);
        if sample_count == 0 {
            return Err(AudioWireError::InvalidSampleCount(sample_count));
        }
        if !(1..=MAX_AUDIO_CHANNELS).contains(&channel_count) {
            return Err(AudioWireError::InvalidChannelCount(channel_count));
        }
        let expected = sample_count
            .checked_mul(channel_count)
            .and_then(|values| values.checked_mul(FLOAT32_BYTES))
            .ok_or(AudioWireError::ByteCountOverflow { sample_count, channel_count })?;
        let samples = reader.rest();
        if expected as usize != samples.len() {
            return Err(AudioWireError::LengthMismatch { declared: expected as usize, actual: samples.len() });
        }
        Ok(Self {
            sample_count,
            channel_count,
            presentation_time: VideoTimestamp { value, timescale },
            samples: samples.to_vec(),
        })
    }
}

/// Swift `AudioCodec.pcmFloat32`: raw interleaved Float32, no compression.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AudioCodec {
    #[serde(rename = "pcmFloat32")]
    PcmFloat32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioStreamConfig {
    pub codec: AudioCodec,
    pub sample_rate: f64,
    pub channel_count: u32,
}

struct Truncated {
    have: usize,
    need: usize,
}

impl From<Truncated> for VideoWireError {
    fn from(truncated: Truncated) -> Self {
        Self::TruncatedHeader { have: truncated.have, need: truncated.need }
    }
}

impl From<Truncated> for AudioWireError {
    fn from(truncated: Truncated) -> Self {
        Self::TruncatedHeader { have: truncated.have, need: truncated.need }
    }
}

/// Reads big endian fields off the front of a payload. A short payload is an error, never a panic.
struct Reader<'a> {
    rest: &'a [u8],
    total: usize,
    header_size: usize,
}

impl<'a> Reader<'a> {
    fn new(bytes: &'a [u8], header_size: usize) -> Self {
        Self { rest: bytes, total: bytes.len(), header_size }
    }

    fn take<const N: usize>(&mut self) -> Result<[u8; N], Truncated> {
        let Some((head, tail)) = self.rest.split_first_chunk::<N>() else {
            return Err(Truncated { have: self.total, need: self.header_size });
        };
        self.rest = tail;
        Ok(*head)
    }

    fn rest(self) -> &'a [u8] {
        self.rest
    }
}

#[cfg(test)]
mod tests {
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
}
