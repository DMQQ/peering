use std::sync::Mutex;

use super::lock;
use crate::ports::clock::Clock;

/// A clock that only moves when the test says so.
#[derive(Debug)]
pub struct FakeClock {
    state: Mutex<ClockState>,
}

#[derive(Debug, Clone, Copy)]
struct ClockState {
    monotonic_seconds: f64,
    unix_seconds: f64,
}

impl FakeClock {
    pub fn new(monotonic_seconds: f64, unix_seconds: u64) -> Self {
        Self {
            state: Mutex::new(ClockState {
                monotonic_seconds,
                unix_seconds: unix_seconds as f64,
            }),
        }
    }

    pub fn advance(&self, seconds: f64) {
        let mut state = lock(&self.state);
        state.monotonic_seconds += seconds;
        state.unix_seconds += seconds;
    }
}

impl Clock for FakeClock {
    fn now_seconds(&self) -> f64 {
        lock(&self.state).monotonic_seconds
    }

    fn unix_seconds(&self) -> u64 {
        lock(&self.state).unix_seconds.floor() as u64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn advance_moves_both_readings_by_the_same_amount() {
        let clock = FakeClock::new(10.0, 1_700_000_000);
        clock.advance(2.5);
        assert_eq!(clock.now_seconds(), 12.5);
        assert_eq!(clock.unix_seconds(), 1_700_000_002);
    }

    #[test]
    fn fractional_wall_time_reads_as_whole_seconds() {
        let clock = FakeClock::new(0.0, 100);
        clock.advance(0.9);
        assert_eq!(clock.unix_seconds(), 100);
        clock.advance(0.2);
        assert_eq!(clock.unix_seconds(), 101);
    }
}
