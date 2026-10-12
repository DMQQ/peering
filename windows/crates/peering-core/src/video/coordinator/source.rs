//! Which display the coordinator captures: starting the default, switching on a client's request, and stopping when nobody
//! is attached.

use peering_wire::quality::even_size;
use peering_wire::source::CaptureSource;

use super::{CoordinatorError, Recovery, VideoCoordinator};
use crate::ports::capture::{Capture, CaptureError};
use crate::ports::encoder::Encoder;

impl<C: Capture, E: Encoder> VideoCoordinator<C, E> {
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
        self.no_frames = false;
        self.recovery = Recovery::default();
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
        self.recovery = Recovery::default();
        self.recovery.restarted(now);
        self.frame_ever_seen = false;
        self.no_frames = false;
        Ok(())
    }
}
