//! Privacy mode: a black cover over every display that the capture does not see, so the phone still sees the desktop.
//! Mirrors `DisplayPrivacyCurtain.swift` and `HostModel.setPrivacyMode` on the Mac.

/// What one cover attempt managed.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CoverReport {
    pub covered: usize,
    /// Displays left visible, such as one where the system would not keep the cover out of capture.
    pub refused: usize,
}

pub trait PrivacyCurtain {
    /// Covers every display now attached, and keeps doing so as displays come and go until `lift`.
    fn cover(&mut self) -> CoverReport;
    fn lift(&mut self);
}

/// A host with no way to cover its displays.
#[derive(Debug, Default)]
pub struct NoCurtain;

impl PrivacyCurtain for NoCurtain {
    fn cover(&mut self) -> CoverReport {
        CoverReport::default()
    }

    fn lift(&mut self) {}
}

/// What the phone is told after a switch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrivacyOutcome {
    /// Nothing worth a word: off, already in the asked state, or every display covered.
    Quiet,
    /// No display could be covered, so privacy mode stays off.
    Failed,
    /// Some displays are covered and this many are still visible.
    Uncovered(usize),
}

/// Host-wide privacy mode over a curtain. Switching on twice covers once, as on the Mac.
pub struct PrivacySwitch {
    curtain: Box<dyn PrivacyCurtain + Send>,
    enabled: bool,
}

impl PrivacySwitch {
    pub fn new(curtain: Box<dyn PrivacyCurtain + Send>) -> Self {
        Self { curtain, enabled: false }
    }

    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    pub fn set(&mut self, enabled: bool) -> PrivacyOutcome {
        if enabled == self.enabled {
            return PrivacyOutcome::Quiet;
        }
        if !enabled {
            self.curtain.lift();
            self.enabled = false;
            return PrivacyOutcome::Quiet;
        }
        let report = self.curtain.cover();
        if report.covered == 0 {
            self.curtain.lift();
            return PrivacyOutcome::Failed;
        }
        self.enabled = true;
        if report.refused > 0 { PrivacyOutcome::Uncovered(report.refused) } else { PrivacyOutcome::Quiet }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[derive(Default)]
    struct Recorded {
        covers: usize,
        lifts: usize,
    }

    struct FakeCurtain(Arc<Mutex<Recorded>>, CoverReport);

    impl PrivacyCurtain for FakeCurtain {
        fn cover(&mut self) -> CoverReport {
            self.0.lock().expect("unpoisoned").covers += 1;
            self.1
        }

        fn lift(&mut self) {
            self.0.lock().expect("unpoisoned").lifts += 1;
        }
    }

    fn switch(report: CoverReport) -> (PrivacySwitch, Arc<Mutex<Recorded>>) {
        let recorded = Arc::new(Mutex::new(Recorded::default()));
        (PrivacySwitch::new(Box::new(FakeCurtain(recorded.clone(), report))), recorded)
    }

    #[test]
    fn switching_on_twice_covers_once_and_off_lifts_once() {
        let (mut privacy, recorded) = switch(CoverReport { covered: 2, refused: 0 });
        assert_eq!(privacy.set(true), PrivacyOutcome::Quiet);
        assert_eq!(privacy.set(true), PrivacyOutcome::Quiet);
        assert!(privacy.is_enabled());
        privacy.set(false);
        privacy.set(false);
        let recorded = recorded.lock().expect("unpoisoned");
        assert_eq!((recorded.covers, recorded.lifts), (1, 1));
    }

    #[test]
    fn nothing_covered_is_a_failure_that_leaves_privacy_off() {
        let (mut privacy, _) = switch(CoverReport::default());
        assert_eq!(privacy.set(true), PrivacyOutcome::Failed);
        assert!(!privacy.is_enabled());
    }

    #[test]
    fn a_display_left_visible_is_reported() {
        let (mut privacy, _) = switch(CoverReport { covered: 1, refused: 1 });
        assert_eq!(privacy.set(true), PrivacyOutcome::Uncovered(1));
        assert!(privacy.is_enabled());
    }
}
