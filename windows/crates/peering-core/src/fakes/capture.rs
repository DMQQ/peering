use std::collections::VecDeque;

use crate::ports::capture::{Capture, CaptureError, DisplayInfo, RawFrame, WindowInfo};

/// Scripted displays and a queue of frames the test pushes. Frames pushed while stopped are discarded on start.
#[derive(Debug)]
pub struct FakeCapture {
    displays: Vec<DisplayInfo>,
    windows: Vec<WindowInfo>,
    running_display: Option<u32>,
    running_window: Option<u32>,
    pending: VecDeque<RawFrame>,
    failed: bool,
    probe_failure: bool,
    start_failures: u32,
    starts: u32,
}

impl FakeCapture {
    pub fn new(displays: Vec<DisplayInfo>) -> Self {
        Self {
            displays,
            windows: Vec::new(),
            running_display: None,
            running_window: None,
            pending: VecDeque::new(),
            failed: false,
            probe_failure: false,
            start_failures: 0,
            starts: 0,
        }
    }

    /// The windows that can be captured from now on.
    pub fn set_windows(&mut self, windows: Vec<WindowInfo>) {
        self.windows = windows;
    }

    pub fn running_window(&self) -> Option<u32> {
        self.running_window
    }

    /// Makes `is_failed` report true until the next successful `start`.
    pub fn fail(&mut self) {
        self.failed = true;
    }

    /// Makes `probe` fail until the next successful `start`.
    pub fn fail_probes(&mut self) {
        self.probe_failure = true;
    }

    /// The next `count` calls to `start` fail.
    pub fn fail_starts(&mut self, count: u32) {
        self.start_failures = count;
    }

    pub fn starts(&self) -> u32 {
        self.starts
    }

    pub fn push_frame(&mut self, frame: RawFrame) {
        self.pending.push_back(frame);
    }

    pub fn running_display(&self) -> Option<u32> {
        self.running_display
    }
}

impl Capture for FakeCapture {
    fn list_displays(&self) -> Vec<DisplayInfo> {
        self.displays.clone()
    }

    fn start(&mut self, display_id: u32) -> Result<(), CaptureError> {
        if !self.displays.iter().any(|display| display.id == display_id) {
            return Err(CaptureError::DisplayNotFound(display_id));
        }
        self.starts += 1;
        if self.start_failures > 0 {
            self.start_failures -= 1;
            return Err(CaptureError::Failed("the device was removed".to_owned()));
        }
        self.failed = false;
        self.probe_failure = false;
        self.running_display = Some(display_id);
        self.running_window = None;
        self.pending.clear();
        Ok(())
    }

    fn list_windows(&self) -> Vec<WindowInfo> {
        self.windows.clone()
    }

    fn start_window(&mut self, window_id: u32) -> Result<(), CaptureError> {
        if !self.windows.iter().any(|window| window.id == window_id) {
            return Err(CaptureError::WindowNotFound(window_id));
        }
        self.starts += 1;
        if self.start_failures > 0 {
            self.start_failures -= 1;
            return Err(CaptureError::Failed("the window could not be captured".to_owned()));
        }
        self.failed = false;
        self.probe_failure = false;
        self.running_window = Some(window_id);
        self.running_display = None;
        self.pending.clear();
        Ok(())
    }

    fn stop(&mut self) {
        self.running_display = None;
        self.running_window = None;
        self.pending.clear();
    }

    fn poll_frame(&mut self) -> Option<RawFrame> {
        self.running_display.or(self.running_window)?;
        self.pending.pop_front()
    }

    fn is_failed(&self) -> bool {
        self.failed
    }

    fn probe(&mut self) -> Result<(), CaptureError> {
        if self.probe_failure {
            return Err(CaptureError::Failed("the duplication cannot be opened".to_owned()));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn display(id: u32) -> DisplayInfo {
        DisplayInfo {
            id,
            name: format!("Display {id}"),
            pixel_width: 3024,
            pixel_height: 1964,
            origin_x: 0,
            origin_y: 0,
            scale: 2.0,
            is_primary: id == 1,
        }
    }

    fn frame(sequence: u64) -> RawFrame {
        RawFrame { width: 3024, height: 1964, sequence }
    }

    #[test]
    fn starting_an_unknown_display_fails() {
        let mut capture = FakeCapture::new(vec![display(1)]);
        assert_eq!(capture.start(9), Err(CaptureError::DisplayNotFound(9)));
        assert_eq!(capture.running_display(), None);
    }

    #[test]
    fn frames_are_delivered_in_order_only_while_running() {
        let mut capture = FakeCapture::new(vec![display(1)]);
        capture.push_frame(frame(1));
        assert_eq!(capture.poll_frame(), None);
        capture.start(1).unwrap();
        capture.push_frame(frame(2));
        capture.push_frame(frame(3));
        assert_eq!(capture.poll_frame().map(|f| f.sequence), Some(2));
        assert_eq!(capture.poll_frame().map(|f| f.sequence), Some(3));
        assert_eq!(capture.poll_frame(), None);
    }

    #[test]
    fn stop_discards_queued_frames() {
        let mut capture = FakeCapture::new(vec![display(1)]);
        capture.start(1).unwrap();
        capture.push_frame(frame(1));
        capture.stop();
        capture.start(1).unwrap();
        assert_eq!(capture.poll_frame(), None);
    }
}
