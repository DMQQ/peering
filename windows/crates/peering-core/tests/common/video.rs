//! Video fakes: a coordinator over shared capture and encoder, and the control source that drives it.

use super::*;
use std::sync::{Arc, Mutex};

use peering_core::fakes::capture::FakeCapture;
use peering_core::fakes::encoder::FakeEncoder;
use peering_core::ports::capture::{Capture, CaptureError, DisplayInfo, RawFrame};
use peering_core::ports::encoder::{EncodeError, EncodedOutput, Encoder};
use peering_core::session::dispatch::SourceControl;
use peering_core::video::coordinator::VideoCoordinator;
use peering_wire::source::CaptureSource;
use peering_wire::video::VideoStreamConfig;

/// A picture whose first one is a keyframe, carrying `size` bytes of data.
pub fn picture(sequence: u8, size: usize) -> peering_wire::video::EncodedVideoFrame {
    peering_wire::video::EncodedVideoFrame {
        is_keyframe: sequence == 1,
        pixel_width: 1920,
        pixel_height: 1080,
        presentation_time: peering_wire::video::VideoTimestamp { value: i64::from(sequence), timescale: 60 },
        data: vec![sequence; size],
    }
}


/// Shares a capture between a test and the coordinator that owns it, so the test can push frames.
#[derive(Clone)]
pub struct SharedCapture(pub Arc<Mutex<FakeCapture>>);

impl Capture for SharedCapture {
    fn list_displays(&self) -> Vec<DisplayInfo> {
        locked(&self.0).list_displays()
    }

    fn start(&mut self, display_id: u32) -> Result<(), CaptureError> {
        locked(&self.0).start(display_id)
    }

    fn stop(&mut self) {
        locked(&self.0).stop();
    }

    fn poll_frame(&mut self) -> Option<RawFrame> {
        locked(&self.0).poll_frame()
    }
}

/// Shares an encoder between a test and the coordinator that owns it, so the test can read the calls made.
#[derive(Clone)]
pub struct SharedEncoder(pub Arc<Mutex<FakeEncoder>>);

impl Encoder for SharedEncoder {
    fn configure(&mut self, width: u32, height: u32, fps: u32, bitrate_bps: u32) -> Result<(), EncodeError> {
        locked(&self.0).configure(width, height, fps, bitrate_bps)
    }

    fn encode(&mut self, frame: &RawFrame, force_keyframe: bool) -> Result<Vec<EncodedOutput>, EncodeError> {
        locked(&self.0).encode(frame, force_keyframe)
    }

    fn set_bitrate(&mut self, bitrate_bps: u32) {
        locked(&self.0).set_bitrate(bitrate_bps);
    }
}

pub type TestCoordinator = VideoCoordinator<SharedCapture, SharedEncoder>;

/// A coordinator over shared fakes, with the displays given. The returned handles are the test's view of the fakes.
pub type CaptureHandle = Arc<Mutex<FakeCapture>>;
pub type EncoderHandle = Arc<Mutex<FakeEncoder>>;

pub fn shared_coordinator(displays: Vec<DisplayInfo>) -> (TestCoordinator, CaptureHandle, EncoderHandle) {
    let capture = Arc::new(Mutex::new(FakeCapture::new(displays)));
    let encoder = Arc::new(Mutex::new(FakeEncoder::default()));
    let coordinator = VideoCoordinator::new(SharedCapture(capture.clone()), SharedEncoder(encoder.clone()));
    (coordinator, capture, encoder)
}

pub fn display_info(id: u32, is_primary: bool) -> DisplayInfo {
    DisplayInfo {
        id,
        name: format!("Display {id}"),
        pixel_width: 1512,
        pixel_height: 982,
        origin_x: if is_primary { 0 } else { 1512 },
        origin_y: 0,
        scale: 2.0,
        is_primary,
    }
}

pub fn raw_frame(sequence: u64) -> RawFrame {
    RawFrame { width: 1512, height: 982, sequence }
}

/// The control source the dispatcher forwards to, backed by a coordinator. Errors the coordinator reports are kept
/// in `rejected`, since the dispatcher has no way to return them.
pub struct CoordinatorControl {
    pub coordinator: TestCoordinator,
    pub now: f64,
    pub rejected: Vec<String>,
}

impl SourceControl for CoordinatorControl {
    fn set_source(&mut self, source: CaptureSource) {
        if let Err(error) = self.coordinator.set_source(source, self.now) {
            self.rejected.push(error.to_string());
        }
    }

    fn set_quality(&mut self, _fps: Option<u32>, bitrate_kbps: Option<u32>) {
        if let Some(kbps) = bitrate_kbps {
            self.coordinator.set_quality(i64::from(kbps));
        }
    }

    fn set_video_enabled(&mut self, enabled: bool) {
        self.coordinator.set_video_enabled(enabled);
    }

    fn lock_screen(&mut self) {}
}

pub fn config_of(outputs: &[peering_core::video::coordinator::VideoOutput]) -> Option<VideoStreamConfig> {
    outputs.iter().find_map(|output| match output {
        peering_core::video::coordinator::VideoOutput::Config(config) => Some(config.clone()),
        _ => None,
    })
}

pub fn keyframe_of(outputs: &[peering_core::video::coordinator::VideoOutput]) -> Option<bool> {
    outputs.iter().find_map(|output| match output {
        peering_core::video::coordinator::VideoOutput::Frame(frame) => Some(frame.is_keyframe),
        _ => None,
    })
}

