use peering_wire::video::{EncodedVideoFrame, VideoCodec, VideoStreamConfig, VideoTimestamp};

use crate::ports::capture::RawFrame;
use crate::ports::encoder::{EncodeError, EncodedOutput, Encoder};

/// Records every call and returns one output per frame. The first frame after `configure`, and every frame with
/// `force_keyframe`, is a keyframe; the first frame after `configure` also carries the stream config.
#[derive(Debug, Default)]
pub struct FakeEncoder {
    configured: Option<(u32, u32, u32)>,
    bitrate_bps: u32,
    config_pending: bool,
    keyframe_pending: bool,
    configure_calls: Vec<(u32, u32, u32, u32)>,
    encode_calls: Vec<(u64, bool)>,
    bitrate_calls: Vec<u32>,
}

impl FakeEncoder {
    pub fn configure_calls(&self) -> &[(u32, u32, u32, u32)] {
        &self.configure_calls
    }

    /// `(sequence, force_keyframe)` for each encode call, in order.
    pub fn encode_calls(&self) -> &[(u64, bool)] {
        &self.encode_calls
    }

    pub fn bitrate_calls(&self) -> &[u32] {
        &self.bitrate_calls
    }

    pub fn bitrate_bps(&self) -> u32 {
        self.bitrate_bps
    }
}

impl Encoder for FakeEncoder {
    fn configure(&mut self, width: u32, height: u32, fps: u32, bitrate_bps: u32) -> Result<(), EncodeError> {
        self.configure_calls.push((width, height, fps, bitrate_bps));
        self.configured = Some((width, height, fps));
        self.bitrate_bps = bitrate_bps;
        self.config_pending = true;
        self.keyframe_pending = true;
        Ok(())
    }

    fn encode(&mut self, frame: &RawFrame, force_keyframe: bool) -> Result<Vec<EncodedOutput>, EncodeError> {
        self.encode_calls.push((frame.sequence, force_keyframe));
        let (width, height, fps) = self.configured.ok_or(EncodeError::NotConfigured)?;
        let is_keyframe = force_keyframe || self.keyframe_pending;
        let config = self.config_pending.then(|| VideoStreamConfig {
            source_id: "fake".to_owned(),
            codec: VideoCodec::H264,
            pixel_width: width,
            pixel_height: height,
            parameter_sets: vec![vec![0x67, 0x42], vec![0x68, 0xce]],
        });
        self.config_pending = false;
        self.keyframe_pending = false;
        let encoded = EncodedVideoFrame {
            is_keyframe,
            pixel_width: width,
            pixel_height: height,
            presentation_time: VideoTimestamp {
                value: frame.sequence as i64,
                timescale: fps.max(1) as i32,
            },
            data: frame.sequence.to_be_bytes().to_vec(),
        };
        Ok(vec![EncodedOutput { config, frame: encoded }])
    }

    fn set_bitrate(&mut self, bitrate_bps: u32) {
        self.bitrate_calls.push(bitrate_bps);
        self.bitrate_bps = bitrate_bps;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn raw(sequence: u64) -> RawFrame {
        RawFrame { width: 1920, height: 1080, sequence }
    }

    #[test]
    fn encode_before_configure_is_an_error() {
        let mut encoder = FakeEncoder::default();
        assert_eq!(encoder.encode(&raw(1), false), Err(EncodeError::NotConfigured));
    }

    #[test]
    fn first_frame_is_a_keyframe_with_config_and_later_frames_are_not() {
        let mut encoder = FakeEncoder::default();
        encoder.configure(1920, 1080, 60, 8_000_000).unwrap();
        let first = encoder.encode(&raw(1), false).unwrap();
        assert!(first[0].frame.is_keyframe);
        assert!(first[0].config.is_some());
        let second = encoder.encode(&raw(2), false).unwrap();
        assert!(!second[0].frame.is_keyframe);
        assert!(second[0].config.is_none());
    }

    #[test]
    fn force_keyframe_produces_a_keyframe_and_calls_are_recorded() {
        let mut encoder = FakeEncoder::default();
        encoder.configure(1280, 720, 30, 4_000_000).unwrap();
        encoder.encode(&raw(1), false).unwrap();
        let forced = encoder.encode(&raw(2), true).unwrap();
        assert!(forced[0].frame.is_keyframe);
        assert_eq!(encoder.encode_calls(), &[(1, false), (2, true)]);
        assert_eq!(encoder.configure_calls(), &[(1280, 720, 30, 4_000_000)]);
    }

    #[test]
    fn set_bitrate_is_recorded_and_applied() {
        let mut encoder = FakeEncoder::default();
        encoder.set_bitrate(2_000_000);
        assert_eq!(encoder.bitrate_calls(), &[2_000_000]);
        assert_eq!(encoder.bitrate_bps(), 2_000_000);
    }
}
