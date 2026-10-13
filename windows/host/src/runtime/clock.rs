use std::time::{Instant, SystemTime, UNIX_EPOCH};

use peering_core::ports::clock::Clock;

pub struct SystemClock {
    started: Instant,
}

impl SystemClock {
    pub fn new() -> Self {
        Self { started: Instant::now() }
    }
}

impl Default for SystemClock {
    fn default() -> Self {
        Self::new()
    }
}

impl Clock for SystemClock {
    fn now_seconds(&self) -> f64 {
        self.started.elapsed().as_secs_f64()
    }

    fn unix_seconds(&self) -> u64 {
        SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_secs())
    }
}
