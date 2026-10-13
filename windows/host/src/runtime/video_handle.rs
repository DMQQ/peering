//! The video coordinator, out of the host state's reach while a capture and encode runs. A pass takes the coordinator
//! onto the encoding thread; whatever the host asks for meanwhile (a phone registering, a source change, a disconnect)
//! is recorded as an intent and applied when the pass gives the coordinator back. Nobody waits for an encode.
//!
//! A pass that runs past its deadline is abandoned: the handle builds a new coordinator on a new capture and encoder, gives
//! it the clients and settings recorded so far, and the thread still inside the old one finds out when (if) it returns and
//! drops what it holds.

use std::any::Any;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex};

use peering_core::supervision::{Handback, PassLedger};
use peering_core::video::coordinator::{CaptureCondition, CoordinatorError, VideoCoordinator, VideoOutput};
use peering_core::video::intent::{IntentQueue, VideoDesired, VideoIntent};
use peering_wire::source::CaptureSource;

use super::diagnostics;
use super::lock::lock_ignoring_poison;
use super::services::{BoxedEncoder, RebuildVideo, SharedCapture};

pub type Coordinator = VideoCoordinator<SharedCapture, BoxedEncoder>;

/// The result of one capture and encode, or the payload of the panic that cut it short.
pub type PumpOutcome = Result<Result<Vec<VideoOutput>, CoordinatorError>, Box<dyn Any + Send>>;

/// What holders of the state lock may read without the coordinator, refreshed whenever it is handed back or changed.
struct View {
    frame_rate: u32,
    running_source: Option<CaptureSource>,
    capture_condition: Option<CaptureCondition>,
    recovery_failures: u32,
}

impl View {
    fn of(coordinator: &Coordinator) -> Self {
        Self {
            frame_rate: coordinator.frame_rate(),
            running_source: coordinator.running_source().cloned(),
            capture_condition: coordinator.capture_condition(),
            recovery_failures: coordinator.recovery_failures(),
        }
    }
}

struct Inner {
    /// `None` while a pass has it.
    coordinator: Option<Coordinator>,
    queue: IntentQueue,
    desired: VideoDesired,
    view: View,
    last_now: f64,
    ledger: PassLedger,
    capture: SharedCapture,
}

#[derive(Clone)]
pub struct VideoHandle {
    inner: Arc<Mutex<Inner>>,
    rebuild: RebuildVideo,
}

impl VideoHandle {
    /// `capture` is the one `coordinator` owns, kept so the host can list displays without it. `rebuild` makes the pair that
    /// replaces them.
    pub fn new(coordinator: Coordinator, capture: SharedCapture, rebuild: RebuildVideo) -> Self {
        let view = View::of(&coordinator);
        let inner = Inner {
            coordinator: Some(coordinator),
            queue: IntentQueue::default(),
            desired: VideoDesired::default(),
            view,
            last_now: 0.0,
            ledger: PassLedger::default(),
            capture,
        };
        Self { inner: Arc::new(Mutex::new(inner)), rebuild }
    }

    /// The capture in use now, which changes when a pass is abandoned.
    pub fn capture(&self) -> SharedCapture {
        self.state().capture.clone()
    }

    /// Whether the pass in flight has run past its deadline.
    pub fn pass_overdue(&self, now: f64) -> bool {
        self.state().ledger.overdue(now)
    }

    /// Gives up on the pass in flight: a new coordinator on a new capture and encoder takes over the clients, settings and
    /// display the old one was asked for, and the clients are told the capture is recovering. Does nothing when the pass
    /// has finished meanwhile. The failure to restart the display on the new device, if any, is returned.
    pub fn abandon_pass(&self, now: f64) -> Result<(), CoordinatorError> {
        let mut inner = self.state();
        if !inner.ledger.abandon() {
            return Ok(());
        }
        let (capture, encoder) = (self.rebuild)();
        let capture = SharedCapture::new(capture);
        let mut fresh = VideoCoordinator::new(capture.clone(), BoxedEncoder(encoder));
        let restored = inner.desired.restore(&mut fresh, now);
        fresh.after_abandoned_pass(now);
        inner.queue.take();
        inner.view = View::of(&fresh);
        inner.coordinator = Some(fresh);
        inner.capture = capture;
        restored
    }

    fn state(&self) -> std::sync::MutexGuard<'_, Inner> {
        lock_ignoring_poison(&self.inner)
    }

    /// Asks for `intent`: done at once when no pass is running, else when the pass in flight finishes. A failure is
    /// returned only for an intent that ran now.
    pub fn apply(&self, intent: VideoIntent, now: f64) -> Result<(), CoordinatorError> {
        let mut inner = self.state();
        inner.last_now = now;
        inner.desired.note(&intent);
        let Inner { coordinator, queue, view, .. } = &mut *inner;
        let Some(coordinator) = coordinator else {
            queue.push(intent);
            return Ok(());
        };
        let result = intent.apply(coordinator, now);
        *view = View::of(coordinator);
        result
    }

    /// An intent that does not depend on the time.
    pub fn request(&self, intent: VideoIntent) {
        let now = self.state().last_now;
        if let Err(error) = self.apply(intent, now) {
            diagnostics::log(&format!("a video change failed: {error}"));
        }
    }

    pub fn frame_rate(&self) -> u32 {
        self.state().view.frame_rate
    }

    pub fn running_source(&self) -> Option<CaptureSource> {
        self.state().view.running_source.clone()
    }

    pub fn capture_condition(&self) -> Option<CaptureCondition> {
        self.state().view.capture_condition
    }

    pub fn recovery_failures(&self) -> u32 {
        self.state().view.recovery_failures
    }

    #[cfg(test)]
    pub fn bitrate_ceiling_kbps(&self) -> Option<u32> {
        self.state().coordinator.as_ref().and_then(Coordinator::bitrate_ceiling_kbps)
    }

    /// One capture and encode. The coordinator is out of reach for its length, a panic is caught and its payload returned,
    /// and the coordinator is handed back either way with the intents that arrived meanwhile applied to it.
    pub fn pump(&self, now: f64) -> PumpOutcome {
        let Some((mut coordinator, pass)) = self.take(now) else {
            return Ok(Ok(Vec::new()));
        };
        let outcome = catch_unwind(AssertUnwindSafe(|| coordinator.pump(now)));
        self.give_back(coordinator, pass, now);
        outcome
    }

    fn take(&self, now: f64) -> Option<(Coordinator, u64)> {
        let mut inner = self.state();
        inner.last_now = now;
        let coordinator = inner.coordinator.take()?;
        let pass = inner.ledger.begin(now);
        Some((coordinator, pass))
    }

    fn give_back(&self, mut coordinator: Coordinator, pass: u64, now: f64) {
        let mut inner = self.state();
        if inner.ledger.finish(pass) == Handback::Abandoned {
            drop(inner);
            drop(coordinator);
            return;
        }
        for intent in inner.queue.take() {
            if let Err(error) = intent.apply(&mut coordinator, now) {
                diagnostics::log(&format!("a video change made while the picture was encoding failed: {error}"));
            }
        }
        inner.view = View::of(&coordinator);
        inner.coordinator = Some(coordinator);
    }
}

#[cfg(test)]
mod tests;
