//! The dispatcher's control source and the context a ready session is dispatched in.

use peering_core::fakes::input::RecordingInput;
use peering_core::ports::input::TransformSnapshot;
use peering_core::session::dispatch::{DispatchContext, SourceControl};

/// Records what the dispatcher asked of the capture and encoder, in order.
#[derive(Debug, Default)]
pub struct RecordingSource {
    pub sources: Vec<peering_wire::source::CaptureSource>,
    pub qualities: Vec<(Option<u32>, Option<u32>)>,
    pub video_enabled: Vec<bool>,
    pub locks: usize,
}

impl SourceControl for RecordingSource {
    fn set_source(&mut self, source: peering_wire::source::CaptureSource) {
        self.sources.push(source);
    }

    fn set_quality(&mut self, fps: Option<u32>, bitrate_kbps: Option<u32>) {
        self.qualities.push((fps, bitrate_kbps));
    }

    fn set_video_enabled(&mut self, enabled: bool) {
        self.video_enabled.push(enabled);
    }

    fn lock_screen(&mut self) {
        self.locks += 1;
    }
}

/// The dispatch context a ready session is given, with the transform the caller computed for its active display.
pub fn dispatch_context<'a>(
    input: &'a mut RecordingInput,
    source: &'a mut dyn SourceControl,
    observe_mode: bool,
) -> DispatchContext<'a> {
    DispatchContext {
        observe_mode,
        transform: TransformSnapshot { origin_x: 0, origin_y: 0, pixel_width: 1512, pixel_height: 982, scale: 2.0 },
        input,
        source,
    }
}

