//! The encode half of the coordinator: reconfiguring the encoder, routing what it produces and working out the bitrate.

use peering_wire::drop_policy::{LatestFrameSlot, PendingFrame};
use peering_wire::quality::default_bitrate_bps;
use peering_wire::video::VideoStreamConfig;

use super::{CoordinatorError, VideoCoordinator, VideoOutput};
use crate::ports::capture::{Capture, RawFrame};
use crate::ports::encoder::{EncodedOutput, Encoder};

/// The shortest wait between keyframes asked for because an encoded frame was dropped.
const DROP_KEYFRAME_INTERVAL: f64 = 1.0;

impl<C: Capture, E: Encoder> VideoCoordinator<C, E> {
    pub(super) fn apply_pending_reconfigure(&mut self) -> Result<(), CoordinatorError> {
        if !std::mem::take(&mut self.reconfigure_pending) {
            return Ok(());
        }
        let (width, height) = self.size;
        self.encoder.configure(width, height, self.pacer.rate(), self.target_bitrate_bps())?;
        self.last_config = None;
        self.config_pending = false;
        self.keyframe_pending = true;
        Ok(())
    }

    pub(super) fn encode_into(
        &mut self,
        raw: &RawFrame,
        now: f64,
        outputs: &mut Vec<VideoOutput>,
        slot: &mut LatestFrameSlot,
    ) -> Result<(), CoordinatorError> {
        let force_keyframe = self.keyframe_pending;
        let encoded = self.encoder.encode(raw, force_keyframe)?;
        self.keyframe_pending = false;
        for output in encoded {
            self.route(output, now, outputs, slot)?;
        }
        Ok(())
    }

    pub(super) fn route(
        &mut self,
        output: EncodedOutput,
        now: f64,
        outputs: &mut Vec<VideoOutput>,
        slot: &mut LatestFrameSlot,
    ) -> Result<(), CoordinatorError> {
        if let Some(config) = output.config {
            let config = self.stamped(config);
            self.last_config = Some(config.clone());
            self.config_pending = false;
            outputs.push(VideoOutput::Config(config));
        } else if self.config_pending {
            if let Some(config) = self.last_config.clone() {
                self.config_pending = false;
                outputs.push(VideoOutput::Config(config));
            }
        }
        let frame = output.frame;
        let is_keyframe = frame.is_keyframe;
        let pending = PendingFrame { is_keyframe, data: frame.encode()? };
        let dropped = slot.offer(pending);
        self.dropped_frames += dropped as u64;
        if dropped > 0 && !is_keyframe {
            self.recover_from_drop(now);
        }
        self.last_frame_at = Some(now);
        Ok(())
    }

    /// An encoded delta that never reached the phone breaks the chain behind it, so the next frame starts a new one. At most once
    /// a second: a keyframe is several times the size of a delta, and a link that is dropping frames cannot take a burst of them.
    fn recover_from_drop(&mut self, now: f64) {
        if self.last_drop_keyframe_at.is_none_or(|last| now - last >= DROP_KEYFRAME_INTERVAL) {
            self.last_drop_keyframe_at = Some(now);
            self.keyframe_pending = true;
        }
    }

    pub(super) fn stamped(&self, mut config: VideoStreamConfig) -> VideoStreamConfig {
        if let Some(source) = &self.source {
            config.source_id = source.stable_id();
        }
        config
    }

    pub(super) fn apply_bitrate(&mut self) {
        if self.source.is_some() {
            self.encoder.set_bitrate(self.target_bitrate_bps());
        }
    }

    pub(super) fn target_bitrate_bps(&self) -> u32 {
        let (width, height) = self.size;
        let wanted = self
            .requested_kbps
            .map(|kbps| kbps.saturating_mul(1000))
            .unwrap_or_else(|| default_bitrate_bps(width, height, self.pacer.rate()));
        match self.ceiling_kbps {
            Some(ceiling) => wanted.min(ceiling.saturating_mul(1000)),
            None => wanted,
        }
    }
}
