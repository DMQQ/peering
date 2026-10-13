//! The sound the PC is playing, as the platform captures it.

/// One piece of captured sound: interleaved Float32 samples in the format the PC mixes in.
#[derive(Debug, Clone, PartialEq)]
pub struct CapturedAudio {
    pub sample_rate: u32,
    pub channels: u32,
    pub samples: Vec<f32>,
}

pub trait AudioSource {
    /// Starts or stops listening. Idempotent. A source that fails to start retries by itself while it is wanted.
    fn set_active(&mut self, active: bool);

    /// What was captured since the last call, oldest first. Never blocks.
    fn drain(&mut self) -> Vec<CapturedAudio>;

    /// Why the source cannot capture right now, if it cannot.
    fn failure(&self) -> Option<String>;
}
