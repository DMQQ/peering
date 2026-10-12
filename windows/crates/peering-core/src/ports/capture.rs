use thiserror::Error;

/// One display as the host reports it to the phone. Coordinates are in points, `pixel_*` in device pixels.
#[derive(Debug, Clone, PartialEq)]
pub struct DisplayInfo {
    pub id: u32,
    pub name: String,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub origin_x: i32,
    pub origin_y: i32,
    pub scale: f64,
    pub is_primary: bool,
}

/// A captured frame before encoding. The pixels stay behind the platform implementation; the core only routes the handle's metadata.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RawFrame {
    pub width: u32,
    pub height: u32,
    pub sequence: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum CaptureError {
    #[error("display {0} is not attached")]
    DisplayNotFound(u32),
    #[error("capture failed: {0}")]
    Failed(String),
}

/// Screen capture for one display at a time. `start` replaces any earlier display. `poll_frame` never blocks and
/// returns None until a frame is ready, and always None while stopped.
pub trait Capture {
    fn list_displays(&self) -> Vec<DisplayInfo>;
    fn start(&mut self, display_id: u32) -> Result<(), CaptureError>;
    fn stop(&mut self);
    fn poll_frame(&mut self) -> Option<RawFrame>;

    /// True when the capture has given up and only a `stop` and `start` can revive it. A capture that is merely waiting
    /// to reacquire its source is not failed.
    fn is_failed(&self) -> bool {
        false
    }

    /// A check that the capture could still deliver, without restarting it and without consuming a frame. A quiet screen
    /// passes; an error means the source or its device is gone. Called when no frame has come for a long time.
    fn probe(&mut self) -> Result<(), CaptureError> {
        Ok(())
    }
}
