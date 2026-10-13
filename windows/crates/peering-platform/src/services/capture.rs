//! Desktop Duplication as the `Capture` port, publishing each acquired frame and its device to the link.

use peering_core::ports::capture::{Capture, CaptureError, DisplayInfo, RawFrame, WindowInfo};

use super::{bound_device, locked, SharedLink};
use crate::dda::DesktopDuplicationCapture;
use crate::wgc::WindowCapture;
use crate::window_list::{capturable_windows, window_rectangle};

/// Which of the two captures is feeding the link.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Source {
    Display,
    Window,
}

pub struct LinkedCapture {
    capture: DesktopDuplicationCapture,
    window: WindowCapture,
    source: Source,
    link: SharedLink,
}

impl LinkedCapture {
    pub fn new(link: SharedLink) -> Self {
        Self { capture: DesktopDuplicationCapture::new(), window: WindowCapture::default(), source: Source::Display, link }
    }
}

impl Capture for LinkedCapture {
    fn list_displays(&self) -> Vec<DisplayInfo> {
        self.capture.list_displays()
    }

    fn start(&mut self, display_id: u32) -> Result<(), CaptureError> {
        self.window.stop();
        self.source = Source::Display;
        let started = self.capture.start(display_id);
        locked(&self.link).bind(bound_device(self.capture.gpu()));
        started
    }

    fn list_windows(&self) -> Vec<WindowInfo> {
        capturable_windows()
    }

    fn window(&self, window_id: u32) -> Option<WindowInfo> {
        window_rectangle(window_id)
    }

    fn start_window(&mut self, window_id: u32) -> Result<(), CaptureError> {
        self.capture.stop();
        self.source = Source::Window;
        let started = self.window.start(window_id, self.capture.gpu());
        locked(&self.link).bind(bound_device(self.window.gpu()));
        started
    }

    fn stop(&mut self) {
        self.capture.stop();
        self.window.stop();
        locked(&self.link).bind(None);
    }

    fn probe(&mut self) -> Result<(), CaptureError> {
        match self.source {
            Source::Display => self.capture.probe(),
            Source::Window => self.window.probe(),
        }
    }

    fn is_failed(&self) -> bool {
        match self.source {
            Source::Display => self.capture.is_failed(),
            Source::Window => self.window.has_failed(),
        }
    }

    fn poll_frame(&mut self) -> Option<RawFrame> {
        if self.source == Source::Window {
            return self.poll_window();
        }
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

impl LinkedCapture {
    fn poll_window(&mut self) -> Option<RawFrame> {
        let (width, height, sequence) = self.window.poll_frame()?;
        let captured = self.window.take_captured();
        let mut link = locked(&self.link);
        link.bind(bound_device(self.window.gpu()));
        if let Some(captured) = captured {
            link.put_frame(captured);
        }
        Some(RawFrame { width, height, sequence })
    }
}
