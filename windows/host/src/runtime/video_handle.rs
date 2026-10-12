//! The video coordinator, out of the host state's reach while a capture and encode runs. A pass takes the coordinator
//! onto the encoding thread; whatever the host asks for meanwhile (a phone registering, a source change, a disconnect)
//! is recorded as an intent and applied when the pass gives the coordinator back. Nobody waits for an encode.

use std::any::Any;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex};

use peering_core::video::coordinator::{CaptureCondition, CoordinatorError, VideoCoordinator, VideoOutput};
use peering_core::video::intent::{IntentQueue, VideoDesired, VideoIntent};
use peering_wire::source::CaptureSource;

use super::diagnostics;
use super::lock::lock_ignoring_poison;
use super::services::{BoxedEncoder, SharedCapture};

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
}

#[derive(Clone)]
pub struct VideoHandle {
    inner: Arc<Mutex<Inner>>,
}

impl VideoHandle {
    pub fn new(coordinator: Coordinator) -> Self {
        let view = View::of(&coordinator);
        let inner = Inner { coordinator: Some(coordinator), queue: IntentQueue::default(), desired: VideoDesired::default(), view, last_now: 0.0 };
        Self { inner: Arc::new(Mutex::new(inner)) }
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
        let Some(mut coordinator) = self.take(now) else {
            return Ok(Ok(Vec::new()));
        };
        let outcome = catch_unwind(AssertUnwindSafe(|| coordinator.pump(now)));
        self.give_back(coordinator, now);
        outcome
    }

    fn take(&self, now: f64) -> Option<Coordinator> {
        let mut inner = self.state();
        inner.last_now = now;
        inner.coordinator.take()
    }

    fn give_back(&self, mut coordinator: Coordinator, now: f64) {
        let mut inner = self.state();
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
