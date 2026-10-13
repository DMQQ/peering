//! Decisions for keeping a long-running loop alive: how long to hold off after a pass panicked, and when a pass that
//! has not come back counts as hung. The host runs the passes; this file only decides.

use crate::video::recovery::retry_delay_seconds;

/// A pass that has been running this long without returning is reported as hung.
pub const HUNG_PASS_SECONDS: f64 = 10.0;

/// Holds a loop off after its pass failed, with the same capped backoff the video recovery uses.
#[derive(Debug, Default)]
pub struct PassGuard {
    failures: u32,
    retry_at: f64,
}

impl PassGuard {
    pub fn ready(&self, now: f64) -> bool {
        now >= self.retry_at
    }

    /// The pass failed at `now`. Returns how long the loop is held off.
    pub fn failed(&mut self, now: f64) -> f64 {
        self.failures = self.failures.saturating_add(1);
        let delay = retry_delay_seconds(self.failures);
        self.retry_at = now + delay;
        delay
    }

    pub fn passed(&mut self) {
        self.failures = 0;
    }

    pub fn failures(&self) -> u32 {
        self.failures
    }
}

/// When the current pass began, so another thread can tell that it never ended.
#[derive(Debug, Default)]
pub struct PassWatch {
    started_at: Option<f64>,
}

impl PassWatch {
    pub fn begin(&mut self, now: f64) {
        self.started_at = Some(now);
    }

    pub fn end(&mut self) {
        self.started_at = None;
    }

    /// How long the pass has been running, once that is past `HUNG_PASS_SECONDS`.
    pub fn hung_for(&self, now: f64) -> Option<f64> {
        self.started_at.map(|started| now - started).filter(|running| *running >= HUNG_PASS_SECONDS)
    }
}

/// A pass that has run this long is given up on and its work replaced, not just reported.
pub const ABANDON_PASS_SECONDS: f64 = HUNG_PASS_SECONDS;

/// Which pass may still hand its work back. A pass that was abandoned and returns later is told so, and drops what it
/// holds instead of putting it where the replacement now is.
#[derive(Debug, Default)]
pub struct PassLedger {
    next: u64,
    running: Option<(u64, f64)>,
}

/// How a pass that is handing back its work stands.
#[derive(Debug, PartialEq, Eq)]
pub enum Handback {
    Current,
    Abandoned,
}

impl PassLedger {
    /// A pass starts at `now`. Its number is how it is recognised when it ends.
    pub fn begin(&mut self, now: f64) -> u64 {
        self.next += 1;
        self.running = Some((self.next, now));
        self.next
    }

    /// Whether the running pass has gone on past the abandon deadline.
    pub fn overdue(&self, now: f64) -> bool {
        self.running.is_some_and(|(_, started)| now - started >= ABANDON_PASS_SECONDS)
    }

    /// Gives up on the running pass. Returns false when none is running.
    pub fn abandon(&mut self) -> bool {
        self.running.take().is_some()
    }

    pub fn finish(&mut self, pass: u64) -> Handback {
        match self.running {
            Some((running, _)) if running == pass => {
                self.running = None;
                Handback::Current
            }
            _ => Handback::Abandoned,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_failed_pass_holds_the_loop_off_with_a_growing_wait() {
        let mut guard = PassGuard::default();
        assert!(guard.ready(0.0));
        assert_eq!(guard.failed(10.0), 0.5);
        assert!(!guard.ready(10.4));
        assert!(guard.ready(10.5));
        assert_eq!(guard.failed(10.5), 1.0);
        assert_eq!(guard.failures(), 2);
    }

    #[test]
    fn the_wait_stops_growing_at_fifteen_seconds() {
        let mut guard = PassGuard::default();
        let waits: Vec<f64> = (0..8).map(|step| guard.failed(f64::from(step))).collect();
        assert_eq!(waits, vec![0.5, 1.0, 2.0, 4.0, 8.0, 15.0, 15.0, 15.0]);
    }

    #[test]
    fn a_pass_that_succeeds_resets_the_wait() {
        let mut guard = PassGuard::default();
        guard.failed(0.0);
        guard.failed(1.0);
        guard.passed();
        assert_eq!(guard.failed(5.0), 0.5);
    }

    #[test]
    fn a_pass_is_hung_only_after_ten_seconds_inside_it() {
        let mut watch = PassWatch::default();
        assert_eq!(watch.hung_for(100.0), None);
        watch.begin(100.0);
        assert_eq!(watch.hung_for(109.9), None);
        assert_eq!(watch.hung_for(110.0), Some(10.0));
    }

    #[test]
    fn a_pass_that_ended_is_not_hung() {
        let mut watch = PassWatch::default();
        watch.begin(0.0);
        watch.end();
        assert_eq!(watch.hung_for(500.0), None);
    }

    #[test]
    fn a_pass_is_overdue_only_after_the_deadline() {
        let mut ledger = PassLedger::default();
        assert!(!ledger.overdue(1_000.0));
        ledger.begin(100.0);
        assert!(!ledger.overdue(109.9));
        assert!(ledger.overdue(110.0));
    }

    #[test]
    fn a_pass_that_ends_in_time_hands_back_normally() {
        let mut ledger = PassLedger::default();
        let pass = ledger.begin(0.0);
        assert_eq!(ledger.finish(pass), Handback::Current);
        assert!(!ledger.overdue(500.0));
    }

    #[test]
    fn a_pass_that_returns_after_being_abandoned_is_told_so_and_cannot_displace_its_successor() {
        let mut ledger = PassLedger::default();
        let stuck = ledger.begin(0.0);
        assert!(ledger.abandon());
        let next = ledger.begin(11.0);
        assert_eq!(ledger.finish(stuck), Handback::Abandoned);
        assert_eq!(ledger.finish(next), Handback::Current);
    }

    #[test]
    fn abandoning_with_nothing_running_does_nothing() {
        assert!(!PassLedger::default().abandon());
    }
}
