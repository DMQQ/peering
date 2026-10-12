mod support;

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use peering_core::fakes::encoder::FakeEncoder;
use peering_core::ports::capture::RawFrame;
use peering_core::ports::encoder::{EncodeError, EncodedOutput, Encoder};
use peering_wire::framing::MessageKind;
use peering_wire::video::EncodedVideoFrame;
use support::*;

struct PanicsOnce {
    inner: FakeEncoder,
    armed: Arc<AtomicBool>,
    encoded: Arc<AtomicUsize>,
}

impl Encoder for PanicsOnce {
    fn configure(&mut self, width: u32, height: u32, fps: u32, bitrate_bps: u32) -> Result<(), EncodeError> {
        self.inner.configure(width, height, fps, bitrate_bps)
    }

    fn encode(&mut self, frame: &RawFrame, force_keyframe: bool) -> Result<Vec<EncodedOutput>, EncodeError> {
        assert!(!self.armed.swap(false, Ordering::SeqCst), "the encoder hit a bug");
        self.encoded.fetch_add(1, Ordering::SeqCst);
        self.inner.encode(frame, force_keyframe)
    }

    fn set_bitrate(&mut self, bitrate_bps: u32) {
        self.inner.set_bitrate(bitrate_bps);
    }
}

#[test]
fn a_panic_in_the_video_pass_resets_the_capture_and_the_picture_resumes_at_a_keyframe() {
    run(async {
        let armed = Arc::new(AtomicBool::new(false));
        let encoded = Arc::new(AtomicUsize::new(0));
        let encoder = PanicsOnce { inner: FakeEncoder::default(), armed: armed.clone(), encoded: encoded.clone() };
        let harness = harness_with_encoder(Box::new(encoder));
        let mut phone = paired_phone(&harness.runtime).await;
        let starts_before = harness.capture.lock().expect("the capture is not poisoned").starts();

        armed.store(true, Ordering::SeqCst);
        harness.runtime.start_pump();
        for sequence in 1.. {
            harness.capture.lock().expect("the capture is not poisoned").push_frame(RawFrame { width: 1920, height: 1080, sequence });
            if !harness.runtime.snapshot().problems.is_empty() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert!(!armed.load(Ordering::SeqCst), "the encoder panicked");

        let mut sequence = 100;
        while encoded.load(Ordering::SeqCst) == 0 {
            harness.clock.advance(0.6);
            sequence += 1;
            harness.capture.lock().expect("the capture is not poisoned").push_frame(RawFrame { width: 1920, height: 1080, sequence });
            tokio::time::sleep(Duration::from_millis(5)).await;
            assert!(sequence < 400, "the pump never recovered");
        }
        let starts_after = harness.capture.lock().expect("the capture is not poisoned").starts();
        assert!(starts_after > starts_before, "the capture was rebuilt, not trusted");
        phone.next_of(MessageKind::VideoConfig).await;
        let frame = EncodedVideoFrame::decode(&phone.next_of(MessageKind::VideoFrame).await.payload).expect("a frame");
        assert!(frame.is_keyframe);
        until(|| harness.runtime.snapshot().problems.is_empty().then_some(())).await;
    });
}
