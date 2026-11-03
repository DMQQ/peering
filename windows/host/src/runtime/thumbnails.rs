//! Keeps the pictures of the sources a phone can choose from. A phone asks for them when its picker opens and while it stays
//! open; the host photographs every window and display on a thread of its own, because a screenshot of a window that is busy
//! can take as long as the window does, and the state lock must not wait for it.

use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use peering_core::ports::thumbnails::{SourceImage, SourceThumbnails};
use peering_wire::source::CaptureSource;

use super::lock::lock_ignoring_poison;

/// How often the pictures are taken again while a picker is open, so a tile follows what its window shows.
const WATCH_INTERVAL_SECONDS: f64 = 3.0;

type Landed = Arc<Mutex<Vec<(String, SourceImage)>>>;

pub struct SourcePictures {
    camera: Arc<dyn SourceThumbnails>,
    refresh_asked: bool,
    watchers: HashSet<u64>,
    last_started_at: Option<f64>,
    landed: Landed,
    running: Arc<AtomicBool>,
}

impl SourcePictures {
    pub fn new(camera: Arc<dyn SourceThumbnails>) -> Self {
        Self {
            camera,
            refresh_asked: false,
            watchers: HashSet::new(),
            last_started_at: None,
            landed: Arc::default(),
            running: Arc::default(),
        }
    }

    /// A phone opened its picker and wants fresh pictures now.
    pub fn refresh(&mut self) {
        self.refresh_asked = true;
    }

    /// A phone's picker is open (`true`) or closed. Pictures are kept fresh only while some picker is open.
    pub fn watch(&mut self, session: u64, watching: bool) {
        if watching {
            self.watchers.insert(session);
        } else {
            self.watchers.remove(&session);
        }
    }

    pub fn forget_session(&mut self, session: u64) {
        self.watchers.remove(&session);
    }

    fn due(&self, now: f64) -> bool {
        if self.running.load(Ordering::Acquire) {
            return false;
        }
        self.refresh_asked
            || (!self.watchers.is_empty() && self.last_started_at.is_none_or(|started| now - started >= WATCH_INTERVAL_SECONDS))
    }

    /// Starts photographing `sources` when a phone wants it and the last round is over.
    pub fn start_if_due(&mut self, now: f64, sources: Vec<CaptureSource>) {
        if !self.due(now) || sources.is_empty() {
            return;
        }
        self.refresh_asked = false;
        self.last_started_at = Some(now);
        self.running.store(true, Ordering::Release);
        let (camera, landed, running) = (self.camera.clone(), self.landed.clone(), self.running.clone());
        let started = std::thread::Builder::new().name("source-pictures".to_owned()).spawn(move || {
            photograph_all(camera.as_ref(), &sources, &landed);
            running.store(false, Ordering::Release);
        });
        if started.is_err() {
            self.running.store(false, Ordering::Release);
        }
    }

    /// The pictures taken since the last call, each with the id of its source.
    pub fn take_landed(&self) -> Vec<(String, SourceImage)> {
        std::mem::take(&mut *lock_ignoring_poison(&self.landed))
    }
}

fn photograph_all(camera: &dyn SourceThumbnails, sources: &[CaptureSource], landed: &Landed) {
    for source in sources {
        if let Some(image) = camera.photograph(source) {
            lock_ignoring_poison(landed).push((source.stable_id(), image));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use peering_core::ports::thumbnails::NoThumbnails;

    struct Fixed;

    impl SourceThumbnails for Fixed {
        fn photograph(&self, source: &CaptureSource) -> Option<SourceImage> {
            matches!(source, CaptureSource::Window { .. }).then(|| SourceImage { width: 2, height: 1, jpeg: vec![1] })
        }
    }

    fn pictures() -> SourcePictures {
        SourcePictures::new(Arc::new(NoThumbnails))
    }

    #[test]
    fn nothing_is_taken_until_a_phone_asks() {
        assert!(!pictures().due(100.0));
    }

    #[test]
    fn a_refresh_is_due_once_and_then_waits_for_the_next_ask() {
        let mut pictures = pictures();
        pictures.refresh();
        assert!(pictures.due(0.0));
        pictures.start_if_due(0.0, vec![CaptureSource::Window { id: 1 }]);
        while pictures.running.load(Ordering::Acquire) {
            std::thread::yield_now();
        }
        assert!(!pictures.due(1.0));
    }

    #[test]
    fn an_open_picker_is_served_again_every_few_seconds() {
        let mut pictures = pictures();
        pictures.watch(7, true);
        assert!(pictures.due(0.0));
        pictures.last_started_at = Some(0.0);
        assert!(!pictures.due(2.0));
        assert!(pictures.due(3.0));
        pictures.watch(7, false);
        assert!(!pictures.due(10.0));
    }

    #[test]
    fn a_session_that_ended_stops_being_watched() {
        let mut pictures = pictures();
        pictures.watch(7, true);
        pictures.forget_session(7);
        assert!(!pictures.due(0.0));
    }

    #[test]
    fn a_round_keeps_the_pictures_it_took_and_skips_the_sources_it_could_not() {
        let landed = Landed::default();
        let sources = [CaptureSource::Display { id: 1 }, CaptureSource::Window { id: 5 }];
        photograph_all(&Fixed, &sources, &landed);
        let taken = std::mem::take(&mut *lock_ignoring_poison(&landed));
        assert_eq!(taken.len(), 1);
        assert_eq!(taken[0].0, "window:5");
    }
}
