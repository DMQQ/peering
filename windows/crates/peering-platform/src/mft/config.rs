//! The H.264 stream description, sent only when it changes (docs/protocol/video.md section 1).

use peering_wire::video::{VideoCodec, VideoStreamConfig};

/// Parameter sets come as a pair. A frame that carries only one of them describes nothing, so it yields no config.
pub fn h264_config(source_id: &str, pixel_width: u32, pixel_height: u32, sps: Option<Vec<u8>>, pps: Option<Vec<u8>>) -> VideoStreamConfig {
    let parameter_sets = match (sps, pps) {
        (Some(sps), Some(pps)) => vec![sps, pps],
        _ => Vec::new(),
    };
    VideoStreamConfig { source_id: source_id.to_owned(), codec: VideoCodec::H264, pixel_width, pixel_height, parameter_sets }
}

#[derive(Debug, Default)]
pub struct ConfigTracker {
    sent: Option<VideoStreamConfig>,
}

impl ConfigTracker {
    /// `Some` only when the candidate has parameter sets and differs from the last one returned.
    pub fn observe(&mut self, candidate: VideoStreamConfig) -> Option<VideoStreamConfig> {
        let changed = VideoStreamConfig::updated(self.sent.as_ref(), candidate)?;
        self.sent = Some(changed.clone());
        Some(changed)
    }
}
