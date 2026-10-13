//! Holds the encoder to the frame rate asked for. The capture runs at the display's rate, so below the default rate only the
//! passes that fall due encode.

use crate::settings::DEFAULT_FRAME_RATE;

/// A pass encodes once this much of a frame interval has passed, so a pump that runs a little early still keeps the rate.
const TOLERANCE: f64 = 0.9;

#[derive(Debug)]
pub struct FramePacer {
    rate: u32,
    last_encoded_at: Option<f64>,
}

impl FramePacer {
    pub fn new(rate: u32) -> Self {
        Self { rate, last_encoded_at: None }
    }

    pub fn rate(&self) -> u32 {
        self.rate
    }

    pub fn set_rate(&mut self, rate: u32) {
        self.rate = rate;
    }

    /// The next pass encodes, whatever the time since the last one, as after a source or a configuration change.
    pub fn restart(&mut self) {
        self.last_encoded_at = None;
    }

    /// At the default rate every pass is due. Below it, a pass is due once a frame interval has passed since the last encode.
    pub fn due(&self, now: f64) -> bool {
        if self.rate >= DEFAULT_FRAME_RATE {
            return true;
        }
        let interval = 1.0 / f64::from(self.rate);
        self.last_encoded_at.is_none_or(|last| now - last >= interval * TOLERANCE)
    }

    pub fn encoded_at(&mut self, now: f64) {
        self.last_encoded_at = Some(now);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn at_the_default_rate_every_pass_is_due_even_at_the_same_time() {
        let mut pacer = FramePacer::new(60);
        pacer.encoded_at(1.0);
        assert!(pacer.due(1.0));
    }

    #[test]
    fn below_the_default_a_pass_is_due_only_after_most_of_an_interval() {
        let mut pacer = FramePacer::new(15);
        pacer.encoded_at(0.0);
        assert!(!pacer.due(0.05));
        assert!(pacer.due(0.06));
    }

    #[test]
    fn a_restart_makes_the_next_pass_due_at_once() {
        let mut pacer = FramePacer::new(15);
        pacer.encoded_at(0.0);
        pacer.restart();
        assert!(pacer.due(0.001));
    }
}
