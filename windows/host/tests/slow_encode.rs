mod support;

use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::Duration;

use peering_core::fakes::encoder::FakeEncoder;
use peering_core::ports::capture::RawFrame;
use peering_core::ports::encoder::{EncodeError, EncodedOutput, Encoder};
use peering_wire::command::RemoteCommand;
use peering_wire::framing::MessageKind;
use peering_wire::source::CaptureSource;
use support::*;

/// An encoder that reports it has started a frame and then waits to be released, like a stalled hardware encoder.
struct GatedEncoder {
    inner: FakeEncoder,
    entered: Sender<()>,
    release: Receiver<()>,
}

impl Encoder for GatedEncoder {
    fn configure(&mut self, width: u32, height: u32, fps: u32, bitrate_bps: u32) -> Result<(), EncodeError> {
        self.inner.configure(width, height, fps, bitrate_bps)
    }

    fn encode(&mut self, frame: &RawFrame, force_keyframe: bool) -> Result<Vec<EncodedOutput>, EncodeError> {
        let _ = self.entered.send(());
        self.release.recv().map_err(|_| EncodeError::Failed("the test ended".to_owned()))?;
        self.inner.encode(frame, force_keyframe)
    }

    fn set_bitrate(&mut self, bitrate_bps: u32) {
        self.inner.set_bitrate(bitrate_bps);
    }
}

#[test]
fn input_and_handshakes_make_progress_while_an_encode_is_in_flight() {
    run(async {
        let (entered_sender, entered) = channel();
        let (release_sender, release) = channel();
        let harness = harness_with_encoder(Box::new(GatedEncoder { inner: FakeEncoder::default(), entered: entered_sender, release }));
        let mut phone = paired_phone(&harness.runtime).await;
        harness.capture.lock().expect("the capture is not poisoned").push_frame(RawFrame { width: 1920, height: 1080, sequence: 1 });
        harness.runtime.start_pump();
        until(|| entered.try_recv().ok()).await;
        phone.send_command(&mouse_move(0.25, 0.75)).await;
        phone.sync().await;
        let moved = harness
            .input
            .lock()
            .expect("the input is not poisoned")
            .applied()
            .iter()
            .any(|(command, _)| matches!(command, RemoteCommand::MouseMove { .. }));
        assert!(moved, "input reached the desktop while the encode was stuck");
        let mut newcomer = Phone::connect(&harness.runtime, direct_peer());
        newcomer.send(role_frame(CONTROL_ROLE)).await;
        newcomer.send(hello_from("99999999-2222-3333-4444-555555555555")).await;
        newcomer.next_of(MessageKind::ServerHello).await;
        newcomer.next_of(MessageKind::PairCommit).await;
        assert_eq!(harness.runtime.snapshot().frame_rate, 60, "the snapshot is readable too");
        release_sender.send(()).expect("the encoder is waiting");
        phone.next_of(MessageKind::VideoFrame).await;
        drop(release_sender);
        tokio::time::sleep(Duration::from_millis(1)).await;
    });
}

/// Starts a pump whose first encode is held, with the phone paired and watching.
async fn stuck_encode(harness: &Harness, entered: &Receiver<()>) -> Phone {
    let phone = paired_phone(&harness.runtime).await;
    harness.capture.lock().expect("the capture is not poisoned").push_frame(RawFrame { width: 1920, height: 1080, sequence: 1 });
    harness.runtime.start_pump();
    until(|| entered.try_recv().ok()).await;
    phone
}

#[test]
fn a_phone_registering_while_an_encode_is_in_flight_is_served_and_attached_after_it() {
    run(async {
        let (entered_sender, entered) = channel();
        let (release_sender, release) = channel();
        let harness = harness_with_two_displays(Box::new(GatedEncoder { inner: FakeEncoder::default(), entered: entered_sender, release }));
        let _first = stuck_encode(&harness, &entered).await;

        let mut again = reconnected_phone(&harness.runtime).await;
        again.sync().await;

        for _ in 0..8 {
            release_sender.send(()).expect("the encoder is waiting");
        }
        for sequence in 2..5 {
            harness.capture.lock().expect("the capture is not poisoned").push_frame(RawFrame { width: 1920, height: 1080, sequence });
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        again.next_of(MessageKind::VideoConfig).await;
        again.next_of(MessageKind::VideoFrame).await;
        drop(release_sender);
        tokio::time::sleep(Duration::from_millis(1)).await;
    });
}

#[test]
fn a_source_change_asked_for_while_an_encode_is_in_flight_is_applied_when_it_finishes() {
    run(async {
        let (entered_sender, entered) = channel();
        let (release_sender, release) = channel();
        let harness = harness_with_two_displays(Box::new(GatedEncoder { inner: FakeEncoder::default(), entered: entered_sender, release }));
        let mut phone = stuck_encode(&harness, &entered).await;

        phone.send_command(&RemoteCommand::SetCaptureSource { source: CaptureSource::Display { id: 2 } }).await;
        phone.sync().await;
        assert_eq!(harness.runtime.snapshot().frame_rate, 60, "the host still answers");
        assert_eq!(harness.capture.lock().expect("the capture is not poisoned").running_display(), Some(1), "the encode still holds the first display");

        release_sender.send(()).expect("the encoder is waiting");
        until(|| (harness.capture.lock().expect("the capture is not poisoned").running_display() == Some(2)).then_some(())).await;
        drop(release_sender);
        tokio::time::sleep(Duration::from_millis(1)).await;
    });
}
