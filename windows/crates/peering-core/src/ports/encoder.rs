use peering_wire::video::{EncodedVideoFrame, VideoStreamConfig};
use thiserror::Error;

use super::capture::RawFrame;

/// One encoded frame, plus the stream description when it changed. `config` is set before the first frame and after each reconfiguration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodedOutput {
    pub config: Option<VideoStreamConfig>,
    pub frame: EncodedVideoFrame,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum EncodeError {
    #[error("encoder is not configured")]
    NotConfigured,
    #[error("unsupported encoder configuration: {0}")]
    Unsupported(String),
    #[error("encoding failed: {0}")]
    Failed(String),
}

/// Turns raw frames into encoded frames. `encode` may return no output for a frame the encoder buffers.
/// `force_keyframe` asks for an IDR frame in that call's output.
pub trait Encoder {
    fn configure(&mut self, width: u32, height: u32, fps: u32, bitrate_bps: u32) -> Result<(), EncodeError>;
    fn encode(&mut self, frame: &RawFrame, force_keyframe: bool) -> Result<Vec<EncodedOutput>, EncodeError>;
    fn set_bitrate(&mut self, bitrate_bps: u32);
}
