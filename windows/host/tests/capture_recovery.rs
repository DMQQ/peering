mod support;

use peering_core::ports::capture::RawFrame;
use peering_core::ports::clock::Clock;
use peering_wire::framing::MessageKind;
use peering_wire::video::EncodedVideoFrame;
use support::*;

fn push_frame(harness: &Harness, sequence: u64) {
    harness
        .capture
        .lock()
        .expect("the capture is not poisoned")
        .push_frame(RawFrame { width: 1920, height: 1080, sequence });
}

#[test]
fn an_encoder_failure_is_a_problem_until_frames_flow_again() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        push_frame(&harness, 1);
        harness.runtime.pump_video(harness.clock.now_seconds()).expect("the first pass encodes");
        phone.next_of(MessageKind::VideoFrame).await;

        harness.encoder.lock().expect("the encoder is not poisoned").fail_encodes(1);
        push_frame(&harness, 2);
        assert!(harness.runtime.pump_video(harness.clock.now_seconds()).is_err());
        assert_eq!(harness.runtime.snapshot().problems.len(), 1);

        harness.clock.advance(0.5);
        push_frame(&harness, 3);
        harness.runtime.pump_video(harness.clock.now_seconds()).expect("the rebuilt encoder encodes");
        let frame: EncodedVideoFrame =
            EncodedVideoFrame::decode(&phone.next_of(MessageKind::VideoFrame).await.payload).expect("a frame");
        assert!(frame.is_keyframe, "the picture resumes at a keyframe");
        assert!(harness.runtime.snapshot().problems.is_empty());
    });
}

#[test]
fn the_pump_goes_quiet_while_the_backoff_runs_instead_of_failing_every_pass() {
    run(async {
        let harness = harness();
        let _phone = paired_phone(&harness.runtime).await;
        push_frame(&harness, 1);
        harness.encoder.lock().expect("the encoder is not poisoned").fail_encodes(1);
        assert!(harness.runtime.pump_video(harness.clock.now_seconds()).is_err());
        for _ in 0..20 {
            harness.clock.advance(0.016);
            push_frame(&harness, 2);
            harness.runtime.pump_video(harness.clock.now_seconds()).expect("a pass inside the backoff does nothing");
        }
        let calls = harness.encoder.lock().expect("the encoder is not poisoned").encode_calls().len();
        assert_eq!(calls, 1, "no frame reached the encoder while it was backing off");
    });
}

#[test]
fn a_recovery_that_fails_twice_is_a_standing_notice_until_frames_flow_again() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        harness.encoder.lock().expect("the encoder is not poisoned").fail_encodes(2);
        for step in 0..3 {
            push_frame(&harness, 1 + step);
            let _ = harness.runtime.pump_video(harness.clock.now_seconds());
            harness.clock.advance(1.5);
        }
        let shown: peering_wire::handshake::NoticePayload = decode_json(&phone.next_of(MessageKind::Notice).await);
        assert_eq!(shown.code.as_deref(), Some("captureRecovering"));

        for step in 0..2 {
            push_frame(&harness, 10 + step);
            harness.runtime.pump_video(harness.clock.now_seconds()).expect("the rebuilt encoder encodes");
            harness.clock.advance(1.5);
        }
        let cleared: peering_wire::handshake::NoticePayload = decode_json(&phone.next_of(MessageKind::Notice).await);
        assert_eq!(cleared.message, None);
    });
}
