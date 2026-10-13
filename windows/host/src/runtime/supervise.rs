//! Keeps the pump loops alive. A pass that panics is caught, logged at a limited rate, shown in the window, and the loop
//! is held off with a growing wait before it runs again. A pass that never returns cannot be interrupted on the single
//! runtime thread, so a monitor thread reports it instead.

use std::any::Any;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

use peering_core::supervision::{PassGuard, PassWatch};
use peering_core::video::recovery::LogGate;

use super::control::HostSnapshot;
use super::diagnostics;
use super::lock::lock_ignoring_poison;
use super::problem_source::ProblemSource;
use super::shared::Shared;

const MONITOR_INTERVAL: Duration = Duration::from_secs(1);

/// One supervised loop: its backoff after panics and the gate on its log lines.
pub(super) struct Supervised {
    name: &'static str,
    guard: PassGuard,
    gate: LogGate,
}

impl Supervised {
    pub(super) fn new(name: &'static str) -> Self {
        Self { name, guard: PassGuard::default(), gate: LogGate::default() }
    }

    /// Whether the loop is out of its backoff, so a pass may run now.
    pub(super) fn ready(&self, now: f64) -> bool {
        self.guard.ready(now)
    }

    /// Runs one pass unless the loop is held off. `problem` is told the sentence to show when a pass panics, and `None`
    /// once a pass succeeds again.
    pub(super) fn run<R>(&mut self, now: f64, pass: impl FnOnce() -> R, problem: impl FnMut(Option<String>)) -> Pass<R> {
        if !self.ready(now) {
            return Pass::Skipped;
        }
        self.settle(now, catch_unwind(AssertUnwindSafe(pass)), problem)
    }

    /// Records how a pass that `ready` allowed ended: a success clears the loop's problem, a panic holds it off.
    pub(super) fn settle<R>(&mut self, now: f64, outcome: std::thread::Result<R>, mut problem: impl FnMut(Option<String>)) -> Pass<R> {
        match outcome {
            Ok(result) => {
                if self.guard.failures() > 0 {
                    self.guard.passed();
                    problem(None);
                }
                Pass::Done(result)
            }
            Err(payload) => {
                let reason = panic_text(payload.as_ref());
                let wait = self.guard.failed(now);
                if let Some(held_back) = self.gate.allow(now) {
                    diagnostics::log(&format!("the {} loop panicked ({reason}); retrying in {wait} s ({held_back} more held back)", self.name));
                }
                problem(Some(format!("The {} loop hit an internal error and is retrying: {reason}", self.name)));
                Pass::Panicked
            }
        }
    }
}

/// How a supervised pass ended.
#[derive(Debug, PartialEq)]
pub(super) enum Pass<R> {
    Skipped,
    Done(R),
    Panicked,
}

/// Shows or clears `source`'s problem in the shared state.
pub(super) fn record_problem(shared: &Shared, source: ProblemSource, text: Option<String>) {
    let mut state = shared.lock();
    match text {
        Some(text) => state.set_problem(source, text),
        None => state.clear_problem(source),
    }
}

fn panic_text(payload: &(dyn Any + Send)) -> String {
    payload
        .downcast_ref::<&str>()
        .map(|text| (*text).to_owned())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "no message".to_owned())
}

/// Shared between the pump, which marks the start and end of each pass, and the monitor thread that reads it.
pub(super) struct PassMeter {
    epoch: Instant,
    watch: Mutex<PassWatch>,
}

impl PassMeter {
    pub(super) fn new() -> Arc<Self> {
        Arc::new(Self { epoch: Instant::now(), watch: Mutex::new(PassWatch::default()) })
    }

    fn seconds(&self) -> f64 {
        self.epoch.elapsed().as_secs_f64()
    }

    fn watch(&self) -> std::sync::MutexGuard<'_, PassWatch> {
        lock_ignoring_poison(&self.watch)
    }

    pub(super) fn begin(&self) {
        let now = self.seconds();
        self.watch().begin(now);
    }

    pub(super) fn end(&self) {
        self.watch().end();
    }

    fn hung_for(&self) -> Option<f64> {
        let now = self.seconds();
        self.watch().hung_for(now)
    }
}

/// Starts the thread that reports a pass that does not return. It writes to the published snapshot, which the hung pass
/// does not hold, and ends when the pump drops the meter. The pump publishes again once it is running, which clears it.
pub(super) fn spawn_hang_monitor(meter: &Arc<PassMeter>, published: Arc<Mutex<HostSnapshot>>) {
    let meter: Weak<PassMeter> = Arc::downgrade(meter);
    let spawned = std::thread::Builder::new().name("hang-monitor".to_owned()).spawn(move || loop {
        std::thread::sleep(MONITOR_INTERVAL);
        let Some(meter) = meter.upgrade() else { return };
        let Some(seconds) = meter.hung_for() else { continue };
        let text = crate::strings::pass_hung(seconds);
        let mut snapshot = lock_ignoring_poison(&published);
        snapshot.problems.retain(|problem| !problem.starts_with(crate::strings::PASS_HUNG_PREFIX));
        snapshot.problems.push(text);
    });
    if let Err(error) = spawned {
        diagnostics::log(&format!("the hang monitor could not start: {error}"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_panicking_pass_is_caught_reported_and_held_off() {
        let mut supervised = Supervised::new("video");
        let mut shown = Vec::new();
        let ran = supervised.run(1.0, || -> u32 { panic!("bad frame") }, |text| shown.push(text));
        assert_eq!(ran, Pass::<u32>::Panicked);
        assert_eq!(shown.len(), 1);
        assert!(shown[0].as_deref().is_some_and(|text| text.contains("bad frame")));

        let mut skipped = false;
        let held = supervised.run(1.2, || skipped = true, |text| shown.push(text));
        assert_eq!(held, Pass::Skipped);
        assert!(!skipped, "the pass does not run inside the backoff");
    }

    #[test]
    fn the_loop_runs_again_after_the_wait_and_clears_its_problem() {
        let mut supervised = Supervised::new("terminals");
        let mut shown = Vec::new();
        let _ = supervised.run(1.0, || panic!("boom"), |text: Option<String>| shown.push(text));
        let ran = supervised.run(1.5, || 7, |text| shown.push(text));
        assert_eq!(ran, Pass::Done(7));
        assert_eq!(shown.last(), Some(&None));
    }

    #[test]
    fn a_healthy_pass_reports_nothing() {
        let mut supervised = Supervised::new("video");
        let mut shown = Vec::new();
        assert_eq!(supervised.run(0.0, || 1, |text: Option<String>| shown.push(text)), Pass::Done(1));
        assert!(shown.is_empty());
    }

    #[test]
    fn a_string_panic_message_is_kept() {
        let mut supervised = Supervised::new("video");
        let mut shown = Vec::new();
        let _ = supervised.run(0.0, || panic!("{}", String::from("formatted")), |text: Option<String>| shown.push(text));
        assert!(shown[0].as_deref().is_some_and(|text| text.contains("formatted")));
    }

    #[test]
    fn a_pass_that_never_started_is_not_hung() {
        let meter = PassMeter::new();
        assert_eq!(meter.hung_for(), None);
        meter.begin();
        assert_eq!(meter.hung_for(), None);
        meter.end();
    }
}
