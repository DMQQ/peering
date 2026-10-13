mod support;

use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::Duration;

use peering_core::fakes::encoder::FakeEncoder;
use peering_core::ports::capture::RawFrame;
use peering_core::ports::encoder::{EncodeError, EncodedOutput, Encoder};
use peering_wire::framing::MessageKind;
use peering_wire::handshake::NoticePayload;
use peering_wire::video::EncodedVideoFrame;
use support::*;
use tokio::task::spawn_local;

/// An encoder that takes a frame and never gives it back until the test lets the thread go, like a wedged driver call.
struct Wedged {
    inner: FakeEncoder,
    entered: Sender<()>,
    release: Receiver<()>,
}

impl Encoder for Wedged {
    fn configure(&mut self, width: u32, height: u32, fps: u32, bitrate_bps: u32) -> Result<(), EncodeError> {
        self.inner.configure(width, height, fps, bitrate_bps)
    }

    fn encode(&mut self, frame: &RawFrame, force_keyframe: bool) -> Result<Vec<EncodedOutput>, EncodeError> {
        let _ = self.entered.send(());
        let _ = self.release.recv();
        self.inner.encode(frame, force_keyframe)
    }

    fn set_bitrate(&mut self, bitrate_bps: u32) {
        self.inner.set_bitrate(bitrate_bps);
    }
}

fn push_frame(harness: &Harness, sequence: u64) {
    harness.capture.lock().expect("the capture is not poisoned").push_frame(RawFrame { width: 1920, height: 1080, sequence });
}

#[test]
fn a_hung_encode_is_abandoned_and_the_picture_resumes_on_a_new_encoder() {
    run(async {
        let (entered_sender, entered) = channel();
        let (release_sender, release) = channel();
        let harness = harness_with_encoder(Box::new(Wedged { inner: FakeEncoder::default(), entered: entered_sender, release }));
        let mut phone = paired_phone(&harness.runtime).await;
        let starts_before = harness.capture.lock().expect("the capture is not poisoned").starts();
        push_frame(&harness, 1);
        harness.runtime.start_pump();
        until(|| entered.try_recv().ok()).await;
        assert!(harness.runtime.snapshot().problems.is_empty(), "nothing is wrong until the deadline");

        harness.clock.advance(11.0);
        until(|| harness.runtime.snapshot().problems.iter().any(|problem| problem.contains("did not answer")).then_some(())).await;
        assert!(
            harness.capture.lock().expect("the capture is not poisoned").starts() > starts_before,
            "the capture was started again on the new device"
        );

        harness.clock.advance(0.6);
        let capture = harness.capture.clone();
        let feeder = spawn_local(async move {
            for sequence in 2..u64::MAX {
                capture.lock().expect("the capture is not poisoned").push_frame(RawFrame { width: 1920, height: 1080, sequence });
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        });
        loop {
            let payload: NoticePayload = decode_json(&phone.next_of(MessageKind::Notice).await);
            if payload.code.as_deref() == Some("captureRecovering") {
                break;
            }
        }

        phone.next_of(MessageKind::VideoConfig).await;
        let frame = EncodedVideoFrame::decode(&phone.next_of(MessageKind::VideoFrame).await.payload).expect("a frame");
        assert!(frame.is_keyframe, "the new encoder starts at a keyframe");
        until(|| harness.runtime.snapshot().problems.is_empty().then_some(())).await;
        feeder.abort();

        release_sender.send(()).expect("the wedged thread is waiting");
        drop(release_sender);
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert!(harness.runtime.snapshot().problems.is_empty(), "the late return of the old thread changed nothing");
    });
}
