//! A focus probe the test feeds.

use std::sync::{Arc, Mutex};

use crate::ports::focus::{FocusProbe, FocusReport};

#[derive(Default)]
struct Inner {
    waiting: Vec<FocusReport>,
    active: bool,
    activations: Vec<bool>,
    taps: Vec<(i32, i32)>,
}

/// Clones share one state, so a test keeps a handle after the probe moves into the host.
#[derive(Clone, Default)]
pub struct ScriptedFocus(Arc<Mutex<Inner>>);

impl ScriptedFocus {
    pub fn report(&self, report: FocusReport) {
        super::lock(&self.0).waiting.push(report);
    }

    pub fn is_active(&self) -> bool {
        super::lock(&self.0).active
    }

    pub fn activations(&self) -> Vec<bool> {
        super::lock(&self.0).activations.clone()
    }

    /// The pixels the host asked about, in order.
    pub fn taps(&self) -> Vec<(i32, i32)> {
        super::lock(&self.0).taps.clone()
    }
}

impl FocusProbe for ScriptedFocus {
    fn set_active(&mut self, active: bool) {
        let mut inner = super::lock(&self.0);
        if inner.active != active {
            inner.active = active;
            inner.activations.push(active);
        }
    }

    fn tapped_at(&mut self, x: i32, y: i32) {
        super::lock(&self.0).taps.push((x, y));
    }

    fn drain(&mut self) -> Vec<FocusReport> {
        let mut inner = super::lock(&self.0);
        if inner.active { std::mem::take(&mut inner.waiting) } else { Vec::new() }
    }
}

/// A PC whose focus cannot be read: used where the platform has no way to watch it.
pub struct BlindFocus;

impl FocusProbe for BlindFocus {
    fn set_active(&mut self, _active: bool) {}

    fn tapped_at(&mut self, _x: i32, _y: i32) {}

    fn drain(&mut self) -> Vec<FocusReport> {
        Vec::new()
    }
}
