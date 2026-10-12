//! Desktop Duplication as the `Capture` port, publishing each acquired frame and its device to the link.

use peering_core::ports::capture::{Capture, CaptureError, DisplayInfo, RawFrame};

use super::{bound_device, locked, SharedLink};
use crate::dda::DesktopDuplicationCapture;

pub struct LinkedCapture {
    capture: DesktopDuplicationCapture,
    link: SharedLink,
}

impl LinkedCapture {
    pub fn new(link: SharedLink) -> Self {
        Self { capture: DesktopDuplicationCapture::new(), link }
    }
}

impl Capture for LinkedCapture {
    fn list_displays(&self) -> Vec<DisplayInfo> {
        self.capture.list_displays()
    }

    fn start(&mut self, display_id: u32) -> Result<(), CaptureError> {
        let started = self.capture.start(display_id);
        locked(&self.link).bind(bound_device(self.capture.gpu()));
        started
    }

    fn stop(&mut self) {
        self.capture.stop();
        locked(&self.link).bind(None);
    }

    fn poll_frame(&mut self) -> Option<RawFrame> {
        let frame = self.capture.poll_frame()?;
        let captured = self.capture.take_captured();
        let mut link = locked(&self.link);
        link.bind(bound_device(self.capture.gpu()));
        if let Some(captured) = captured {
            link.put_frame(captured);
        }
        Some(frame)
    }
}
