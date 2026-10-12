//! The recovery wrapped around a pump pass: rebuild the capture and encoder after a failure with a capped backoff, and
//! restart a capture that has gone quiet.

use peering_wire::quality::even_size;
use peering_wire::source::CaptureSource;

use super::{CoordinatorError, VideoCoordinator, VideoOutput};
use crate::ports::capture::{Capture, CaptureError};
use crate::ports::encoder::Encoder;
use crate::video::recovery::{remedy_for, Recovery, Remedy};

impl<C: Capture, E: Encoder> VideoCoordinator<C, E> {
    /// Takes every frame the capture has ready, encodes it while anyone is watching, and returns what to send.
    /// Only the newest frame survives a burst, except that a keyframe is never lost to a delta behind it.
    ///
    /// A failure is returned once and then the pump goes quiet until the backoff runs out, when it rebuilds what failed
    /// and tries again. A capture that stops delivering without an error is restarted after a stall is noticed.
    pub fn pump(&mut self, now: f64) -> Result<Vec<VideoOutput>, CoordinatorError> {
        self.note_capture_health(now);
        if self.watchdog_expired(now) {
            self.no_frames = true;
        }
        if self.recovery.waiting(now) {
            return Ok(Vec::new());
        }
        if let Some(remedy) = self.recovery.due(now) {
            self.attempt_rebuild(remedy, now)?;
        }
        match self.pump_pass(now) {
            Ok(outputs) => {
                if outputs.iter().any(|output| matches!(output, VideoOutput::Frame(_))) {
                    self.recovery.produced_output();
                }
                self.schedule_restart_if_stalled(now);
                Ok(outputs)
            }
            Err(error) => {
                self.recovery.failed(remedy_for(&error), now);
                Err(error)
            }
        }
    }

    /// After a pass panicked part way through its update, what the coordinator holds cannot be trusted. Attached clients and
    /// the chosen source are kept; everything else about the running capture is dropped and rebuilt, after the usual
    /// backoff, as if the pipeline had failed. The clients are owed a description and a keyframe.
    pub fn reset_after_panic(&mut self, now: f64) {
        self.last_config = None;
        self.reconfigure_pending = false;
        self.capture_started_at = None;
        self.frame_ever_seen = false;
        self.no_frames = false;
        self.recovery = Recovery::default();
        self.request_resync();
        if self.source.is_some() {
            self.recovery.failed(Remedy::Pipeline, now);
        }
    }

    /// Failures in a row since the last frame came out.
    pub fn recovery_failures(&self) -> u32 {
        self.recovery.failures()
    }

    fn note_capture_health(&mut self, now: f64) {
        if self.source.is_some() && self.capture.is_failed() {
            self.recovery.capture_failed(now);
        }
    }

    /// Judged after the pass, so frames that were waiting count: a pump that was not called for a while is not a stall.
    fn schedule_restart_if_stalled(&mut self, now: f64) {
        if !self.stalled(now) {
            return;
        }
        if self.frame_ever_seen {
            self.recovery.stall_probe_started(now);
            if self.capture.probe().is_ok() {
                return;
            }
        }
        self.recovery.failed(Remedy::Pipeline, now);
    }

    /// A capture that never delivered, or one that delivered and then went quiet while someone was watching. A still
    /// screen looks the same, so a capture that delivered before is probed, and rebuilt only when the probe fails. The
    /// client hears of it only if the rebuild fails.
    fn stalled(&mut self, now: f64) -> bool {
        if self.source.is_none() || !self.sending() {
            self.recovery.idle(now);
            return false;
        }
        if self.frame_ever_seen {
            self.recovery.stalled(now)
        } else {
            self.watchdog_expired(now)
        }
    }

    fn attempt_rebuild(&mut self, remedy: Remedy, now: f64) -> Result<(), CoordinatorError> {
        let rebuilt = self.rebuild(remedy, now);
        if let Err(error) = &rebuilt {
            self.recovery.failed(remedy_for(error), now);
        }
        rebuilt
    }

    fn rebuild(&mut self, remedy: Remedy, now: f64) -> Result<(), CoordinatorError> {
        let Some(CaptureSource::Display { id }) = self.source.clone() else {
            self.recovery.rebuilt(now);
            return Ok(());
        };
        if remedy == Remedy::Resync {
            self.request_resync();
            self.recovery.rebuilt(now);
            return Ok(());
        }
        if remedy == Remedy::Pipeline {
            self.capture.stop();
            let display = self
                .capture
                .list_displays()
                .into_iter()
                .find(|display| display.id == id)
                .ok_or(CaptureError::DisplayNotFound(id))?;
            self.capture.start(id)?;
            self.size = even_size(display.pixel_width, display.pixel_height);
        }
        let (width, height) = self.size;
        self.encoder.configure(width, height, self.pacer.rate(), self.target_bitrate_bps())?;
        self.last_config = None;
        self.config_pending = false;
        self.keyframe_pending = true;
        self.reconfigure_pending = false;
        self.pacer.restart();
        self.capture_started_at = Some(now);
        self.frame_ever_seen = false;
        self.recovery.rebuilt(now);
        Ok(())
    }
}
