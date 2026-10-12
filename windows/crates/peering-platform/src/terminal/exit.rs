//! When a shell that has exited counts as finished. The console may still be delivering its last output when the
//! process is seen to end, so the exit is held back until the output has been quiet for a moment.

pub const OUTPUT_GRACE_SECONDS: f64 = 0.15;

#[derive(Debug, Default)]
pub struct ExitTracker {
    exit_code: Option<i32>,
    quiet_since: f64,
}

impl ExitTracker {
    pub fn output_arrived(&mut self, now: f64) {
        self.quiet_since = now;
    }

    /// Records the exit code the first time the process is seen to have ended.
    pub fn observe(&mut self, polled: Option<i32>, now: f64) {
        if self.exit_code.is_none() {
            if let Some(code) = polled {
                self.exit_code = Some(code);
                self.quiet_since = self.quiet_since.max(now);
            }
        }
    }

    pub fn has_exited(&self) -> bool {
        self.exit_code.is_some()
    }

    /// The exit code once the output has been quiet for the grace period. `output_closed` is the reader reaching
    /// the end of the stream, which says there is nothing more to wait for.
    pub fn finished(&self, now: f64, output_closed: bool) -> Option<i32> {
        let code = self.exit_code?;
        (output_closed || now - self.quiet_since >= OUTPUT_GRACE_SECONDS).then_some(code)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_running_shell_has_not_finished() {
        let mut tracker = ExitTracker::default();
        tracker.observe(None, 10.0);
        assert_eq!(tracker.finished(99.0, false), None);
        assert!(!tracker.has_exited());
    }

    #[test]
    fn an_exit_waits_for_the_output_to_go_quiet() {
        let mut tracker = ExitTracker::default();
        tracker.observe(Some(3), 10.0);
        assert_eq!(tracker.finished(10.05, false), None);
        tracker.output_arrived(10.1);
        assert_eq!(tracker.finished(10.2, false), None);
        assert_eq!(tracker.finished(10.26, false), Some(3));
    }

    #[test]
    fn a_closed_output_ends_the_wait() {
        let mut tracker = ExitTracker::default();
        tracker.observe(Some(0), 10.0);
        assert_eq!(tracker.finished(10.0, true), Some(0));
    }

    #[test]
    fn the_first_exit_code_is_kept() {
        let mut tracker = ExitTracker::default();
        tracker.observe(Some(7), 1.0);
        tracker.observe(Some(9), 2.0);
        assert_eq!(tracker.finished(5.0, false), Some(7));
    }
}
