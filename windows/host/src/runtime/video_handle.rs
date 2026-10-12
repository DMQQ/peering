//! The video coordinator behind its own lock, so a capture and encode in flight does not hold the host state. Whoever holds
//! the guard is the only writer. Lock order: the state lock may be held while taking this one, never the reverse.

use std::any::Any;
use std::ops::{Deref, DerefMut};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex, MutexGuard};

use peering_core::video::coordinator::{CoordinatorError, VideoCoordinator, VideoOutput};
use peering_wire::source::CaptureSource;

use super::lock::lock_ignoring_poison;
use super::services::{BoxedEncoder, SharedCapture};

pub type Coordinator = VideoCoordinator<SharedCapture, BoxedEncoder>;

/// The result of one capture and encode, or the payload of the panic that cut it short.
pub type PumpOutcome = Result<Result<Vec<VideoOutput>, CoordinatorError>, Box<dyn Any + Send>>;

struct View {
    frame_rate: u32,
    running_source: Option<CaptureSource>,
}

impl View {
    fn of(coordinator: &Coordinator) -> Self {
        Self { frame_rate: coordinator.frame_rate(), running_source: coordinator.running_source().cloned() }
    }
}

/// The coordinator, plus a view of it that holders of the state lock may read without waiting for an encode. The guard
/// refreshes the view when it is released.
#[derive(Clone)]
pub struct VideoHandle {
    coordinator: Arc<Mutex<Coordinator>>,
    view: Arc<Mutex<View>>,
}

impl VideoHandle {
    pub fn new(coordinator: Coordinator) -> Self {
        let view = View::of(&coordinator);
        Self { coordinator: Arc::new(Mutex::new(coordinator)), view: Arc::new(Mutex::new(view)) }
    }

    /// Waits for the capture and encode in flight, if any.
    pub fn lock(&self) -> VideoGuard<'_> {
        VideoGuard { guard: lock_ignoring_poison(&self.coordinator), view: &self.view }
    }

    pub fn frame_rate(&self) -> u32 {
        lock_ignoring_poison(&self.view).frame_rate
    }

    pub fn running_source(&self) -> Option<CaptureSource> {
        lock_ignoring_poison(&self.view).running_source.clone()
    }

    /// One capture and encode. A panic is caught and its payload returned, so the guard is released normally.
    pub fn pump(&self, now: f64) -> PumpOutcome {
        let mut coordinator = self.lock();
        catch_unwind(AssertUnwindSafe(|| coordinator.pump(now)))
    }
}

pub struct VideoGuard<'a> {
    guard: MutexGuard<'a, Coordinator>,
    view: &'a Mutex<View>,
}

impl Deref for VideoGuard<'_> {
    type Target = Coordinator;

    fn deref(&self) -> &Coordinator {
        &self.guard
    }
}

impl DerefMut for VideoGuard<'_> {
    fn deref_mut(&mut self) -> &mut Coordinator {
        &mut self.guard
    }
}

impl Drop for VideoGuard<'_> {
    fn drop(&mut self) {
        *lock_ignoring_poison(self.view) = View::of(&self.guard);
    }
}
