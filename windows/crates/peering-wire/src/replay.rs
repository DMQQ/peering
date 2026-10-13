//! Datagram replay window of 64 with a bitmap. `accepts` does not mutate: a forged datagram with a huge counter must not drag the window.

pub const WINDOW_SIZE: u64 = 64;

#[derive(Debug, Default, Clone)]
pub struct ReplayWindow {
    highest: u64,
    seen: u64,
    started: bool,
}

impl ReplayWindow {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn accepts(&self, counter: u64) -> bool {
        if !self.started || counter > self.highest {
            return true;
        }
        let distance = self.highest - counter;
        distance < WINDOW_SIZE && self.seen & (1 << distance) == 0
    }

    /// Call only after the datagram authenticated.
    pub fn commit(&mut self, counter: u64) {
        if !self.started {
            self.started = true;
            self.highest = counter;
            self.seen = 1;
            return;
        }
        if counter > self.highest {
            let shift = counter - self.highest;
            self.seen = if shift >= WINDOW_SIZE { 0 } else { self.seen << shift };
            self.seen |= 1;
            self.highest = counter;
        } else {
            self.seen |= 1 << (self.highest - counter);
        }
    }

    pub fn reset(&mut self) {
        *self = Self::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vectors_dir::load;

    #[test]
    fn follows_the_vector_steps() {
        let steps = load("crypto.json")["replayWindow"]["steps"].clone();
        let mut window = ReplayWindow::new();
        for step in steps.as_array().unwrap() {
            let counter = step["counter"].as_u64().unwrap();
            assert_eq!(window.accepts(counter), step["accepts"].as_bool().unwrap(), "counter {counter}");
            if step["commit"].as_bool() == Some(true) {
                window.commit(counter);
            }
        }
    }

    #[test]
    fn a_forged_jump_does_not_poison_the_window() {
        let mut window = ReplayWindow::new();
        window.commit(10);
        assert!(window.accepts(u64::MAX));
        assert!(window.accepts(11), "the check alone moved nothing");
    }

    #[test]
    fn a_jump_wider_than_the_window_forgets_old_counters() {
        let mut window = ReplayWindow::new();
        window.commit(1);
        window.commit(1000);
        assert!(!window.accepts(1), "far behind the window");
        assert!(window.accepts(999));
    }

    #[test]
    fn reset_accepts_anything_again() {
        let mut window = ReplayWindow::new();
        window.commit(9);
        window.reset();
        assert!(window.accepts(9));
    }
}
