//! Desktop Duplication capture of one monitor. The state machine and the HRESULT decision are pure; `dda/sys.rs`
//! drives the DXGI and D3D11 objects.

#[cfg(windows)]
mod sys;

#[cfg(windows)]
pub use sys::DesktopDuplicationCapture;

const INITIAL_BACKOFF_SECONDS: f64 = 0.25;
const MAX_BACKOFF_SECONDS: f64 = 4.0;

/// What the OS call returned, reduced to the cases the capture reacts to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HresultKind {
    Success,
    WaitTimeout,
    AccessLost,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Classification {
    NewFrame,
    NoNewFrame,
    /// The duplication must be recreated; the desktop is secure, locked or switched.
    AccessLost,
    Fatal,
}

pub fn classify(kind: HresultKind) -> Classification {
    match kind {
        HresultKind::Success => Classification::NewFrame,
        HresultKind::WaitTimeout => Classification::NoNewFrame,
        HresultKind::AccessLost => Classification::AccessLost,
        HresultKind::Other => Classification::Fatal,
    }
}

/// Retry wait after `losses` consecutive access losses: doubles from 0.25 s and stops at 4 s.
pub fn backoff_seconds(losses: u32) -> f64 {
    let exponent = losses.saturating_sub(1).min(16);
    (INITIAL_BACKOFF_SECONDS * f64::from(1u32 << exponent)).min(MAX_BACKOFF_SECONDS)
}

/// `Running` and `Lost` count consecutive access losses since the last frame, so backoff keeps growing while the
/// secure desktop stays up. Times are seconds on any monotonic clock the caller picks.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum CaptureState {
    Idle,
    Running { losses: u32 },
    Lost { losses: u32, retry_at: f64 },
    Failed,
}

impl CaptureState {
    pub fn start(&mut self) {
        *self = Self::Running { losses: 0 };
    }

    pub fn stop(&mut self) {
        *self = Self::Idle;
    }

    pub fn fail(&mut self) {
        *self = Self::Failed;
    }

    pub fn frame_arrived(&mut self) {
        if let Self::Running { losses } = self {
            *losses = 0;
        }
    }

    pub fn access_lost(&mut self, now: f64) {
        let losses = match *self {
            Self::Running { losses } | Self::Lost { losses, .. } => losses.saturating_add(1),
            Self::Idle | Self::Failed => return,
        };
        *self = Self::Lost { losses, retry_at: now + backoff_seconds(losses) };
    }

    pub fn reacquire_due(&self, now: f64) -> bool {
        matches!(*self, Self::Lost { retry_at, .. } if now >= retry_at)
    }

    pub fn reacquired(&mut self) {
        if let Self::Lost { losses, .. } = *self {
            *self = Self::Running { losses };
        }
    }

    pub fn reacquire_failed(&mut self, now: f64) {
        self.access_lost(now);
    }

    pub fn is_running(&self) -> bool {
        matches!(self, Self::Running { .. })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hresults_classify_as_frame_timeout_access_lost_or_fatal() {
        assert_eq!(classify(HresultKind::Success), Classification::NewFrame);
        assert_eq!(classify(HresultKind::WaitTimeout), Classification::NoNewFrame);
        assert_eq!(classify(HresultKind::AccessLost), Classification::AccessLost);
        assert_eq!(classify(HresultKind::Other), Classification::Fatal);
    }

    #[test]
    fn backoff_doubles_from_a_quarter_second_and_caps_at_four() {
        assert_eq!(backoff_seconds(1), 0.25);
        assert_eq!(backoff_seconds(2), 0.5);
        assert_eq!(backoff_seconds(3), 1.0);
        assert_eq!(backoff_seconds(5), 4.0);
        assert_eq!(backoff_seconds(500), 4.0);
        assert_eq!(backoff_seconds(0), 0.25);
    }

    #[test]
    fn start_begins_running_with_no_losses() {
        let mut state = CaptureState::Idle;
        state.start();
        assert_eq!(state, CaptureState::Running { losses: 0 });
    }

    #[test]
    fn stop_returns_to_idle_from_any_state() {
        let mut state = CaptureState::Failed;
        state.stop();
        assert_eq!(state, CaptureState::Idle);
    }

    #[test]
    fn events_are_ignored_while_idle_or_failed() {
        let mut idle = CaptureState::Idle;
        idle.access_lost(1.0);
        assert_eq!(idle, CaptureState::Idle);

        let mut failed = CaptureState::Failed;
        failed.access_lost(1.0);
        assert_eq!(failed, CaptureState::Failed);
    }

    #[test]
    fn access_loss_moves_to_lost_with_the_first_backoff() {
        let mut state = CaptureState::Running { losses: 0 };
        state.access_lost(10.0);
        assert_eq!(state, CaptureState::Lost { losses: 1, retry_at: 10.25 });
    }

    #[test]
    fn reacquire_waits_until_the_retry_time() {
        let mut state = CaptureState::Running { losses: 0 };
        state.access_lost(10.0);
        assert!(!state.reacquire_due(10.24));
        assert!(state.reacquire_due(10.25));
    }

    #[test]
    fn repeated_losses_back_off_until_the_cap() {
        let mut state = CaptureState::Running { losses: 0 };
        state.access_lost(0.0);
        state.reacquired();
        state.access_lost(0.0);
        assert_eq!(state, CaptureState::Lost { losses: 2, retry_at: 0.5 });
        state.reacquire_failed(1.0);
        assert_eq!(state, CaptureState::Lost { losses: 3, retry_at: 2.0 });
        for _ in 0..10 {
            state.reacquire_failed(2.0);
        }
        assert_eq!(state, CaptureState::Lost { losses: 13, retry_at: 6.0 });
    }

    #[test]
    fn a_frame_after_recovery_resets_the_losses() {
        let mut state = CaptureState::Running { losses: 0 };
        state.access_lost(0.0);
        state.reacquired();
        state.frame_arrived();
        assert_eq!(state, CaptureState::Running { losses: 0 });
        state.access_lost(5.0);
        assert_eq!(state, CaptureState::Lost { losses: 1, retry_at: 5.25 });
    }

    #[test]
    fn losses_persist_through_a_recovery_that_has_not_produced_a_frame() {
        let mut state = CaptureState::Running { losses: 0 };
        state.access_lost(0.0);
        state.reacquired();
        assert_eq!(state, CaptureState::Running { losses: 1 });
        state.access_lost(0.0);
        assert_eq!(state, CaptureState::Lost { losses: 2, retry_at: 0.5 });
    }

    #[test]
    fn frames_while_lost_do_not_resume_capture() {
        let mut state = CaptureState::Running { losses: 0 };
        state.access_lost(0.0);
        state.frame_arrived();
        assert!(!state.is_running());
    }
}
