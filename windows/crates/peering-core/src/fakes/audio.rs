//! An audio source the test feeds.

use std::sync::{Arc, Mutex};

use crate::ports::audio::{AudioSource, CapturedAudio};

#[derive(Default)]
struct Inner {
    waiting: Vec<CapturedAudio>,
    active: bool,
    activations: Vec<bool>,
    failure: Option<String>,
}

/// Clones share one state, so a test keeps a handle after the source moves into the host.
#[derive(Clone, Default)]
pub struct ScriptedAudio(Arc<Mutex<Inner>>);

impl ScriptedAudio {
    pub fn feed(&self, packet: CapturedAudio) {
        super::lock(&self.0).waiting.push(packet);
    }

    pub fn fail_with(&self, reason: &str) {
        super::lock(&self.0).failure = Some(reason.to_owned());
    }

    pub fn is_active(&self) -> bool {
        super::lock(&self.0).active
    }

    /// Every distinct change of the active state, in order.
    pub fn activations(&self) -> Vec<bool> {
        super::lock(&self.0).activations.clone()
    }
}

impl AudioSource for ScriptedAudio {
    fn set_active(&mut self, active: bool) {
        let mut inner = super::lock(&self.0);
        if inner.active != active {
            inner.active = active;
            inner.activations.push(active);
        }
    }

    fn drain(&mut self) -> Vec<CapturedAudio> {
        let mut inner = super::lock(&self.0);
        if inner.active { std::mem::take(&mut inner.waiting) } else { Vec::new() }
    }

    fn failure(&self) -> Option<String> {
        super::lock(&self.0).failure.clone()
    }
}

/// A PC with nothing to listen to: used where the platform has no way to capture sound.
pub struct SilentAudio;

impl AudioSource for SilentAudio {
    fn set_active(&mut self, _active: bool) {}

    fn drain(&mut self) -> Vec<CapturedAudio> {
        Vec::new()
    }

    fn failure(&self) -> Option<String> {
        None
    }
}
