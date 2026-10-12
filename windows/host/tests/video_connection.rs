mod support;

use std::time::Duration;

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

fn pump(harness: &Harness) {
    harness.runtime.pump_video(harness.clock.now_seconds()).expect("the pump runs");
}

async fn video_connection(harness: &Harness) -> Phone {
    let mut video = Phone::connect(&harness.runtime, direct_peer());
    video.send(role_frame(VIDEO_ROLE)).await;
    video
}

#[test]
fn a_phone_that_chooses_no_source_is_shown_the_primary_display() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        phone.next_of(MessageKind::Catalog).await;
        push_frame(&harness, 1);
        pump(&harness);
        phone.next_of(MessageKind::VideoConfig).await;
        phone.next_of(MessageKind::VideoFrame).await;
    });
}

#[test]
fn capture_stops_when_the_last_phone_leaves() {
    run(async {
        let harness = harness();
        let phone = paired_phone(&harness.runtime).await;
        assert_eq!(harness.capture.lock().expect("the capture is not poisoned").running_display(), Some(1));
        drop(phone);
        until(|| harness.capture.lock().expect("the capture is not poisoned").running_display().is_none().then_some(())).await;
    });
}

#[test]
fn a_video_connection_opened_after_the_first_frames_is_sent_the_config_and_a_keyframe() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        push_frame(&harness, 1);
        pump(&harness);
        phone.next_of(MessageKind::VideoFrame).await;

        let mut video = video_connection(&harness).await;
        phone.sync().await;
        push_frame(&harness, 2);
        pump(&harness);

        video.next_of(MessageKind::VideoConfig).await;
        let picture = video.next_of(MessageKind::VideoFrame).await;
        let frame = EncodedVideoFrame::decode(&picture.payload).expect("the video frame decodes");
        assert!(frame.is_keyframe);
    });
}

#[test]
fn a_video_connection_attaches_to_the_newest_session_of_the_phone() {
    run(async {
        let harness = harness();
        let mut older = paired_phone(&harness.runtime).await;
        let mut newer = reconnected_phone(&harness.runtime).await;
        let mut video = video_connection(&harness).await;
        newer.sync().await;
        push_frame(&harness, 1);
        pump(&harness);

        video.next_of(MessageKind::VideoConfig).await;
        newer.send(peering_wire::framing::Frame::empty(MessageKind::Ping)).await;
        loop {
            let frame = newer.next().await;
            assert_ne!(frame.kind, MessageKind::VideoConfig, "the newest session's video goes on the video connection");
            if frame.kind == MessageKind::Pong {
                break;
            }
        }
        older.sync().await;
    });
}

#[test]
fn an_older_session_closing_leaves_the_newer_sessions_video_and_input() {
    run(async {
        let harness = harness();
        let older = paired_phone(&harness.runtime).await;
        let mut newer = reconnected_phone(&harness.runtime).await;
        let mut video = video_connection(&harness).await;
        newer.sync().await;
        let released_before = harness.input.lock().expect("the input is not poisoned").release_all_count();

        drop(older);
        newer.sync().await;
        until(|| (harness.runtime.snapshot().connected_clients == 1).then_some(())).await;
        push_frame(&harness, 1);
        pump(&harness);

        video.next_of(MessageKind::VideoFrame).await;
        assert_eq!(harness.input.lock().expect("the input is not poisoned").release_all_count(), released_before);
    });
}

#[test]
fn a_video_connection_that_never_speaks_outlives_the_silence_limit() {
    let executor = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .start_paused(true)
        .build()
        .expect("an executor starts");
    tokio::task::LocalSet::new().block_on(&executor, async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        let mut video = video_connection(&harness).await;
        phone.sync().await;

        for _ in 0..4 {
            harness.clock.advance(20.0);
            tokio::time::sleep(Duration::from_secs(2)).await;
            phone.sync().await;
        }
        push_frame(&harness, 1);
        pump(&harness);

        video.next_of(MessageKind::VideoFrame).await;
    });
}
