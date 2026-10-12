//! What the encoder is asked for. 4:2:0 needs even sides, so they round down; a zero bitrate means the default for the size.

use peering_core::ports::encoder::EncodeError;
use peering_wire::quality::{default_bitrate_bps, even_size};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EncoderSettings {
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub bitrate_bps: u32,
}

impl EncoderSettings {
    pub fn new(width: u32, height: u32, fps: u32, bitrate_bps: u32) -> Result<Self, EncodeError> {
        let (width, height) = even_size(width, height);
        if width == 0 || height == 0 || fps == 0 {
            return Err(EncodeError::Unsupported(format!("{width}x{height} at {fps} fps")));
        }
        let bitrate_bps = if bitrate_bps == 0 { default_bitrate_bps(width, height, fps) } else { bitrate_bps };
        Ok(Self { width, height, fps, bitrate_bps })
    }

    /// Two seconds of frames, the keyframe interval the Mac host uses.
    pub fn gop_size(&self) -> u32 {
        self.fps.saturating_mul(2)
    }
}
