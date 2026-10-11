use std::collections::VecDeque;

use crate::ports::capture::{Capture, CaptureError, DisplayInfo, RawFrame};

/// Scripted displays and a queue of frames the test pushes. Frames pushed while stopped are discarded on start.
#[derive(Debug)]
pub struct FakeCapture {
    displays: Vec<DisplayInfo>,
    running_display: Option<u32>,
    pending: VecDeque<RawFrame>,
}

impl FakeCapture {
    pub fn new(displays: Vec<DisplayInfo>) -> Self {
        Self {
            displays,
            running_display: None,
            pending: VecDeque::new(),
        }
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
        self.running_display = Some(display_id);
        self.pending.clear();
        Ok(())
    }

    fn stop(&mut self) {
        self.running_display = None;
        self.pending.clear();
    }

    fn poll_frame(&mut self) -> Option<RawFrame> {
        self.running_display?;
        self.pending.pop_front()
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
