//! Capture and encode for the clients attached to the video channel. Driven by explicit calls: the caller pumps it
//! with the time and sends what comes back.

use std::collections::BTreeSet;

use peering_wire::drop_policy::LatestFrameSlot;
use peering_wire::quality::{clamped_bitrate_kbps, even_size};
use peering_wire::source::CaptureSource;
use peering_wire::video::{EncodedVideoFrame, VideoStreamConfig, VideoWireError};
use thiserror::Error;

use crate::ports::capture::{Capture, CaptureError};
use crate::ports::encoder::{EncodeError, Encoder};
use crate::settings::{snap_frame_rate, DEFAULT_FRAME_RATE};

mod encoding;
mod pacing;

use pacing::FramePacer;

/// How long a capture may run before the watchdog treats a frame-less start as a failure.
pub const FIRST_FRAME_GRACE: f64 = 5.0;

#[derive(Debug, Clone, PartialEq)]
pub enum VideoOutput {
    Config(VideoStreamConfig),
    Frame(EncodedVideoFrame),
}

#[derive(Debug, Error)]
pub enum CoordinatorError {
    #[error("only display sources can be captured, not {0}")]
    UnsupportedSource(String),
    #[error(transparent)]
    Capture(#[from] CaptureError),
    #[error(transparent)]
    Encode(#[from] EncodeError),
    #[error(transparent)]
    Wire(#[from] VideoWireError),
}

pub struct VideoCoordinator<C: Capture, E: Encoder> {
    capture: C,
    encoder: E,
    clients: BTreeSet<String>,
    video_enabled: bool,
    source: Option<CaptureSource>,
    chosen_source: Option<CaptureSource>,
    size: (u32, u32),
    last_config: Option<VideoStreamConfig>,
    config_pending: bool,
    keyframe_pending: bool,
    requested_kbps: Option<u32>,
    ceiling_kbps: Option<u32>,
    pacer: FramePacer,
    reconfigure_pending: bool,
    capture_started_at: Option<f64>,
    frame_ever_seen: bool,
    watchdog_reported: bool,
    last_frame_at: Option<f64>,
    dropped_frames: u64,
}

impl<C: Capture, E: Encoder> VideoCoordinator<C, E> {
    pub fn new(capture: C, encoder: E) -> Self {
        Self {
            capture,
            encoder,
            clients: BTreeSet::new(),
            video_enabled: true,
            source: None,
            chosen_source: None,
            size: (0, 0),
            last_config: None,
            config_pending: false,
            keyframe_pending: false,
            requested_kbps: None,
            ceiling_kbps: None,
            pacer: FramePacer::new(DEFAULT_FRAME_RATE),
            reconfigure_pending: false,
            capture_started_at: None,
            frame_ever_seen: false,
            watchdog_reported: false,
            last_frame_at: None,
            dropped_frames: 0,
        }
    }

    /// A new client needs a description and a recovery point before any delta frame reaches it.
    pub fn attach(&mut self, client_id: &str) {
        self.clients.insert(client_id.to_owned());
        self.request_resync();
    }

    /// The next encoded frame is a keyframe preceded by the stream description. A connection that opens after the
    /// first frames went out (the client's video socket) needs this to have anything to decode.
    pub fn request_resync(&mut self) {
        self.keyframe_pending = true;
        self.config_pending = true;
    }

    pub fn detach(&mut self, client_id: &str) {
        self.clients.remove(client_id);
    }

    /// Clears the source a client chose once nobody is attached. Capture keeps running, so a client that
    /// reconnects soon still gets a picture without a restart.
    pub fn forget_chosen_source_if_idle(&mut self) {
        if self.clients.is_empty() {
            self.chosen_source = None;
        }
    }

    /// Starts capture when nothing is running: the source a client chose, else the primary display, else the first.
    /// The default is not recorded as a choice, so it is dropped again when the last client leaves.
    pub fn ensure_capturing(&mut self, now: f64) -> Result<(), CoordinatorError> {
        if self.source.is_some() {
            return Ok(());
        }
        let target = match self.chosen_source.clone() {
            Some(source) => source,
            None => {
                let displays = self.capture.list_displays();
                let display = displays
                    .iter()
                    .find(|display| display.is_primary)
                    .or_else(|| displays.first())
                    .ok_or_else(|| CaptureError::Failed("no display is attached".to_owned()))?;
                CaptureSource::Display { id: display.id }
            }
        };
        let chosen = self.chosen_source.clone();
        self.set_source(target, now)?;
        self.chosen_source = chosen;
        Ok(())
    }

    /// Once nobody is attached the capture is stopped and the client's choice forgotten, so the next client starts
    /// from the default display rather than from whatever the last one left running.
    pub fn stop_when_idle(&mut self) {
        if !self.clients.is_empty() {
            return;
        }
        self.forget_chosen_source_if_idle();
        self.capture.stop();
        self.source = None;
        self.last_config = None;
        self.capture_started_at = None;
        self.frame_ever_seen = false;
        self.watchdog_reported = false;
    }

    /// Switches capture to a display. A switch to the source already running changes nothing.
    pub fn set_source(&mut self, source: CaptureSource, now: f64) -> Result<(), CoordinatorError> {
        let id = match &source {
            CaptureSource::Display { id } => *id,
            other => return Err(CoordinatorError::UnsupportedSource(other.stable_id())),
        };
        if self.source.as_ref() == Some(&source) {
            self.chosen_source = Some(source);
            return Ok(());
        }
        let display = self
            .capture
            .list_displays()
            .into_iter()
            .find(|display| display.id == id)
            .ok_or(CaptureError::DisplayNotFound(id))?;
        self.source = None;
        self.capture.start(id)?;
        self.size = even_size(display.pixel_width, display.pixel_height);
        let (width, height) = self.size;
        self.encoder.configure(width, height, self.pacer.rate(), self.target_bitrate_bps())?;
        self.source = Some(source.clone());
        self.chosen_source = Some(source);
        self.last_config = None;
        self.config_pending = false;
        self.keyframe_pending = true;
        self.reconfigure_pending = false;
        self.pacer.restart();
        self.capture_started_at = Some(now);
        self.frame_ever_seen = false;
        self.watchdog_reported = false;
        Ok(())
    }

    /// Sets the frame rate the encoder runs at, snapped to an allowed rate. A running source is reconfigured on the next
    /// pump, which asks for a keyframe, and the connections stay up.
    pub fn set_frame_rate(&mut self, fps: u32) {
        let fps = snap_frame_rate(fps);
        if fps == self.pacer.rate() {
            return;
        }
        self.pacer.set_rate(fps);
        self.reconfigure_pending = self.source.is_some();
    }

    pub fn frame_rate(&self) -> u32 {
        self.pacer.rate()
    }

    /// Applies a bitrate the client asked for. Values the wire bounds reject are ignored, not an error.
    pub fn set_quality(&mut self, bitrate_kbps: i64) {
        let Some(kbps) = clamped_bitrate_kbps(bitrate_kbps) else { return };
        self.requested_kbps = Some(kbps);
        self.apply_bitrate();
    }

    /// The most the encoder may run at, whatever the client asked for. The control channel uses this.
    pub fn set_bitrate_ceiling(&mut self, ceiling_kbps: Option<u32>) {
        self.ceiling_kbps = ceiling_kbps;
        self.apply_bitrate();
    }

    /// Pausing drops what is captured and keeps the connections. Resuming starts again with a description and a keyframe.
    pub fn set_video_enabled(&mut self, enabled: bool) {
        if enabled && !self.video_enabled {
            self.keyframe_pending = true;
            self.config_pending = true;
        }
        self.video_enabled = enabled;
    }

    /// Takes every frame the capture has ready, encodes it while anyone is watching, and returns what to send.
    /// Only the newest frame survives a burst, except that a keyframe is never lost to a delta behind it.
    pub fn pump(&mut self, now: f64) -> Result<Vec<VideoOutput>, CoordinatorError> {
        let mut outputs = Vec::new();
        let mut slot = LatestFrameSlot::new();
        self.apply_pending_reconfigure()?;
        let encode_this_pass = self.pacer.due(now);
        let mut encoded = false;
        while let Some(raw) = self.capture.poll_frame() {
            self.frame_ever_seen = true;
            if encode_this_pass && self.sending() {
                self.encode_into(&raw, now, &mut outputs, &mut slot)?;
                encoded = true;
            }
        }
        if encoded {
            self.pacer.encoded_at(now);
        }
        if let Some(pending) = slot.take() {
            outputs.push(VideoOutput::Frame(EncodedVideoFrame::decode(&pending.data)?));
        }
        Ok(outputs)
    }

    /// True when no frame has ever arrived and the grace period since the capture started has passed.
    /// A capture that has delivered anything is never reported this way, so a still screen is not a failure.
    pub fn watchdog_expired(&self, now: f64) -> bool {
        !self.frame_ever_seen
            && self.capture_started_at.is_some_and(|started| now - started >= FIRST_FRAME_GRACE)
    }

    /// True once per capture start, the first time the watchdog has expired, so a silent capture is reported once.
    pub fn take_watchdog_report(&mut self, now: f64) -> bool {
        if self.watchdog_reported || !self.watchdog_expired(now) {
            return false;
        }
        self.watchdog_reported = true;
        true
    }

    pub fn running_source(&self) -> Option<&CaptureSource> {
        self.source.as_ref()
    }

    pub fn chosen_source(&self) -> Option<&CaptureSource> {
        self.chosen_source.as_ref()
    }

    /// When the encoder last produced a frame, for deciding whether a missing picture is the network's fault.
    pub fn last_frame_produced_at(&self) -> Option<f64> {
        self.last_frame_at
    }

    pub fn dropped_frames(&self) -> u64 {
        self.dropped_frames
    }

    fn sending(&self) -> bool {
        self.video_enabled && !self.clients.is_empty() && self.source.is_some()
    }
}

#[cfg(test)]
mod tests;
