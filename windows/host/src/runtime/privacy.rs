//! Privacy mode off the host's lock. Covering waits up to seconds for the curtain's thread, so it runs on the blocking
//! pool; each run applies the newest wish, so a quick on then off ends off whichever run goes last.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use peering_core::ports::curtain::{PrivacyCurtain, PrivacyOutcome, PrivacySwitch};
use tokio::task::JoinHandle;

use super::lock::lock_ignoring_poison;

#[derive(Clone)]
pub struct PrivacyControl(Arc<Inner>);

struct Inner {
    switch: Mutex<PrivacySwitch>,
    wanted: AtomicBool,
}

impl PrivacyControl {
    pub fn new(curtain: Box<dyn PrivacyCurtain + Send>) -> Self {
        Self(Arc::new(Inner { switch: Mutex::new(PrivacySwitch::new(curtain)), wanted: AtomicBool::new(false) }))
    }

    /// Returns at once; the handle gives the outcome of the run that applied this wish or a newer one.
    pub fn request(&self, enabled: bool) -> JoinHandle<PrivacyOutcome> {
        self.0.wanted.store(enabled, Ordering::SeqCst);
        let inner = self.0.clone();
        tokio::task::spawn_blocking(move || {
            let mut switch = lock_ignoring_poison(&inner.switch);
            let wanted = inner.wanted.load(Ordering::SeqCst);
            switch.set(wanted)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use peering_core::ports::curtain::CoverReport;
    use std::sync::mpsc;

    struct GatedCurtain {
        gate: Mutex<mpsc::Receiver<()>>,
        covered: Arc<AtomicBool>,
    }

    impl PrivacyCurtain for GatedCurtain {
        fn cover(&mut self) -> CoverReport {
            let _opened = self.gate.lock().expect("unpoisoned").recv();
            self.covered.store(true, Ordering::SeqCst);
            CoverReport { covered: 1, refused: 0 }
        }

        fn lift(&mut self) {
            self.covered.store(false, Ordering::SeqCst);
        }
    }

    fn gated() -> (PrivacyControl, mpsc::Sender<()>, Arc<AtomicBool>) {
        let (open, gate) = mpsc::channel();
        let covered = Arc::new(AtomicBool::new(false));
        let curtain = GatedCurtain { gate: Mutex::new(gate), covered: covered.clone() };
        (PrivacyControl::new(Box::new(curtain)), open, covered)
    }

    #[tokio::test(flavor = "current_thread")]
    async fn asking_returns_before_the_curtain_has_covered() {
        let (privacy, open, covered) = gated();
        let running = privacy.request(true);
        assert!(!covered.load(Ordering::SeqCst));
        open.send(()).expect("open");
        assert_eq!(running.await.expect("runs"), PrivacyOutcome::Quiet);
        assert!(covered.load(Ordering::SeqCst));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn on_then_off_ends_off() {
        let (privacy, open, covered) = gated();
        let on = privacy.request(true);
        let off = privacy.request(false);
        open.send(()).expect("open");
        let _ = (on.await, off.await);
        assert!(!covered.load(Ordering::SeqCst));
    }
}
