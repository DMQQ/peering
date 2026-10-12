mod support;

use std::time::Duration;

use peering_core::ports::capture::RawFrame;
use peering_core::ports::clock::Clock;
use peering_wire::framing::MessageKind;
use peering_wire::handshake::ClientStatePayload;
use peering_wire::video::EncodedVideoFrame;
use support::*;

fn push_frame(harness: &Harness, sequence: u64) {
    harness
        .capture
        .lock()
        .expect("the capture is not poisoned")
        .push_frame(RawFrame { width: 1920, height: 1080, sequence });
}

fn pump(harness: &Harness) {
    harness.runtime.pump_video(harness.clock.now_seconds()).expect("the pump runs");
}

fn encoded_frames(harness: &Harness) -> usize {
    harness.encoder.lock().expect("the encoder is not poisoned").encode_calls().len()
}

async fn report(phone: &mut Phone, background: bool) {
    phone.send_json(MessageKind::ClientState, &ClientStatePayload { background }).await;
    phone.sync().await;
}

async fn silence_for(harness: &Harness, seconds: u32) {
    for _ in 0..seconds / 20 {
        harness.clock.advance(20.0);
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}

#[test]
fn the_host_declares_that_it_understands_client_state() {
    run(async {
        let harness = harness();
        let mut phone = Phone::connect(&harness.runtime, direct_peer());
        phone.send(role_frame(CONTROL_ROLE)).await;
        phone.send(hello()).await;
        let declared = server_hello(&phone.next_of(MessageKind::ServerHello).await);
        assert_eq!(declared.capabilities.supports_client_state, Some(true));
    });
}

#[test]
fn a_backgrounded_phone_costs_no_encoding() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        report(&mut phone, true).await;
        let before = encoded_frames(&harness);

        push_frame(&harness, 1);
        pump(&harness);

        assert_eq!(encoded_frames(&harness), before);
    });
}

#[test]
fn returning_to_the_foreground_resumes_video_with_a_config_and_a_keyframe() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        push_frame(&harness, 1);
        pump(&harness);
        phone.next_of(MessageKind::VideoFrame).await;
        report(&mut phone, true).await;
        push_frame(&harness, 2);
        pump(&harness);

        report(&mut phone, false).await;
        push_frame(&harness, 3);
        pump(&harness);

        phone.next_of(MessageKind::VideoConfig).await;
        let picture = phone.next_of(MessageKind::VideoFrame).await;
        let frame = EncodedVideoFrame::decode(&picture.payload).expect("the video frame decodes");
        assert!(frame.is_keyframe);
        assert_eq!(harness.encoder.lock().expect("the encoder is not poisoned").encode_calls().last(), Some(&(3, true)));
    });
}

#[test]
fn a_backgrounded_phone_is_kept_through_two_minutes_of_silence() {
    run_paused(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        report(&mut phone, true).await;

        silence_for(&harness, 120).await;

        phone.sync().await;
    });
}

#[test]
fn a_backgrounded_phone_silent_past_three_minutes_is_dropped() {
    run_paused(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        report(&mut phone, true).await;

        silence_for(&harness, 200).await;

        while phone.try_next().await.is_some() {}
    });
}

#[test]
fn a_phone_that_returned_is_dropped_after_sixty_seconds_of_silence_again() {
    run_paused(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        report(&mut phone, true).await;
        report(&mut phone, false).await;

        silence_for(&harness, 80).await;

        while phone.try_next().await.is_some() {}
    });
}
