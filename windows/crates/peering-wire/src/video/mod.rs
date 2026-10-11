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
mod tests;
