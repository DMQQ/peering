//! The decisions behind recovering a capture or encoder that stopped working: which failures are worth another try, how
//! long to wait between tries, when a silent capture counts as stalled, and how often a repeating failure is logged.
//! Pure and driven by the caller's clock, so the policy is tested without a GPU.

use super::coordinator::CoordinatorError;
use crate::ports::capture::CaptureError;
use crate::ports::encoder::EncodeError;

/// Waits after the first, second and later failures in a row. The last step repeats.
const RETRY_DELAYS: [f64; 6] = [0.5, 1.0, 2.0, 4.0, 8.0, 15.0];
/// Encoder rebuilds that fail this many times in a row are taken to mean the device under it is gone.
const ENCODER_REBUILDS_BEFORE_DEVICE_REBUILD: u32 = 2;
/// Failures in a row after which the client is shown the capture is recovering.
const FAILURES_BEFORE_REPORT: u32 = 2;
/// A capture that has produced frames and then none for this long is restarted once.
pub const STALL_SECONDS: f64 = 30.0;
/// The longest the stall probe waits when restarts keep finding a still screen.
const MAXIMUM_STALL_SECONDS: f64 = 300.0;
/// A frame this long after a restart is the screen changing, not the restart's own first frame.
const ORGANIC_FRAME_AFTER_SECONDS: f64 = 1.0;
const LOG_INTERVAL_SECONDS: f64 = 10.0;

/// What to rebuild after a failure.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Remedy {
    /// Stop and start the capture, which creates a new D3D device and duplication, then configure the encoder on it.
    Pipeline,
    /// Configure the encoder again, dropping what it holds.
    Encoder,
    /// Nothing is broken; the client needs a description and a keyframe.
    Resync,
    /// Trying again is unlikely to help until a setting changes, so it is tried rarely.
    Unrecoverable,
}

pub fn remedy_for(error: &CoordinatorError) -> Remedy {
    match error {
        CoordinatorError::Capture(CaptureError::DisplayNotFound(_) | CaptureError::Failed(_)) => Remedy::Pipeline,
        CoordinatorError::Encode(EncodeError::NotConfigured | EncodeError::Failed(_)) => Remedy::Encoder,
        CoordinatorError::Wire(_) => Remedy::Resync,
        CoordinatorError::Encode(EncodeError::Unsupported(_)) | CoordinatorError::UnsupportedSource(_) => Remedy::Unrecoverable,
    }
}

/// The wait before try number `failures` (1 for the first).
pub fn retry_delay_seconds(failures: u32) -> f64 {
    let index = (failures.saturating_sub(1) as usize).min(RETRY_DELAYS.len() - 1);
    RETRY_DELAYS[index]
}

/// The stall window after `quiet_probes` restarts that found nothing but their own first frame: it doubles up to a cap.
pub fn stall_window_seconds(quiet_probes: u32) -> f64 {
    (STALL_SECONDS * f64::from(1u32 << quiet_probes.min(8))).min(MAXIMUM_STALL_SECONDS)
}

/// Tracks failures in a row, the wait they impose and what the next attempt rebuilds.
#[derive(Debug, Default)]
pub struct Recovery {
    failures: u32,
    encoder_failures: u32,
    retry_at: f64,
    remedy: Option<Remedy>,
    last_organic_frame_at: Option<f64>,
    restarted_at: Option<f64>,
    quiet_probes: u32,
}

impl Recovery {
    /// A failure at `now`. The next attempt waits out the backoff and rebuilds what `remedy` says, widening to the whole
    /// pipeline when the encoder alone keeps failing.
    pub fn failed(&mut self, remedy: Remedy, now: f64) {
        self.failures = self.failures.saturating_add(1);
        self.retry_at = now + retry_delay_seconds(self.failures);
        self.remedy = match remedy {
            Remedy::Encoder => {
                self.encoder_failures = self.encoder_failures.saturating_add(1);
                if self.encoder_failures > ENCODER_REBUILDS_BEFORE_DEVICE_REBUILD {
                    Some(Remedy::Pipeline)
                } else {
                    Some(Remedy::Encoder)
                }
            }
            Remedy::Resync => Some(Remedy::Resync),
            Remedy::Pipeline => Some(Remedy::Pipeline),
            Remedy::Unrecoverable => Some(Remedy::Unrecoverable),
        };
        if remedy == Remedy::Unrecoverable {
            self.retry_at = now + RETRY_DELAYS[RETRY_DELAYS.len() - 1];
        }
    }

    /// The capture reports itself failed without a call having returned an error.
    pub fn capture_failed(&mut self, now: f64) {
        if self.remedy != Some(Remedy::Pipeline) {
            self.failed(Remedy::Pipeline, now);
        }
    }

    /// True while the backoff has not run out, so the pump does nothing this pass.
    pub fn waiting(&self, now: f64) -> bool {
        self.remedy.is_some() && now < self.retry_at
    }

    /// What to rebuild now, once the backoff has run out.
    pub fn due(&self, now: f64) -> Option<Remedy> {
        self.remedy.filter(|_| now >= self.retry_at)
    }

    /// The rebuild ran. Backoff is cleared only by `produced_output`, because a rebuild can succeed and fail again at once.
    pub fn rebuilt(&mut self, now: f64) {
        self.remedy = None;
        self.restarted_at = Some(now);
    }

    /// An encoded frame came out, so whatever failed is working again.
    pub fn produced_output(&mut self) {
        self.failures = 0;
        self.encoder_failures = 0;
    }

    pub fn failures(&self) -> u32 {
        self.failures
    }

    /// True while rebuilds keep failing: a second attempt has also failed and no frame has come out since.
    pub fn visibly_failing(&self) -> bool {
        self.failures >= FAILURES_BEFORE_REPORT
    }

    /// A raw frame arrived from the capture at `now`.
    pub fn frame_seen(&mut self, now: f64) {
        if self.restarted_at.is_none_or(|restarted| now - restarted > ORGANIC_FRAME_AFTER_SECONDS) {
            self.quiet_probes = 0;
        }
        self.last_organic_frame_at = Some(now);
    }

    /// Nobody is looking or nothing is captured, so silence means nothing. Restarts the stall clock.
    pub fn idle(&mut self, now: f64) {
        self.last_organic_frame_at = Some(now);
    }

    /// True when a capture that was delivering has gone quiet for the stall window, with no recovery under way.
    pub fn stalled(&self, now: f64) -> bool {
        self.remedy.is_none()
            && self
                .last_organic_frame_at
                .is_some_and(|last| now - last >= stall_window_seconds(self.quiet_probes))
    }

    /// The stall is being answered with a restart.
    pub fn stall_probe_started(&mut self, now: f64) {
        self.quiet_probes = self.quiet_probes.saturating_add(1);
        self.last_organic_frame_at = Some(now);
    }

    /// A new capture start (a source change) forgets what the old one did.
    pub fn restarted(&mut self, now: f64) {
        self.last_organic_frame_at = Some(now);
        self.restarted_at = Some(now);
        self.quiet_probes = 0;
    }
}

/// Lets a repeating message through once per interval.
#[derive(Debug, Default)]
pub struct LogGate {
    last_at: Option<f64>,
    suppressed: u64,
}

impl LogGate {
    /// The number of messages held back since the last one let through, when this one passes; `None` when held back.
    pub fn allow(&mut self, now: f64) -> Option<u64> {
        if self.last_at.is_some_and(|last| now - last < LOG_INTERVAL_SECONDS) {
            self.suppressed += 1;
            return None;
        }
        self.last_at = Some(now);
        Some(std::mem::take(&mut self.suppressed))
    }
}

#[cfg(test)]
mod tests;
