mod support;

use peering_core::ports::clock::Clock;
use peering_wire::framing::MessageKind;
use peering_wire::handshake::{ErrorPayload, NoticePayload};
use support::*;

fn security_prompt() -> NoticePayload {
    NoticePayload {
        message: Some("A Windows security prompt is on screen".to_owned()),
        symbol: Some("exclamationmark.shield.fill".to_owned()),
        locked_display_id: None,
    }
}

fn set_notice(harness: &Harness, notice: Option<NoticePayload>) {
    harness.system.lock().expect("the system is not poisoned").set_notice(notice);
}

fn pump(harness: &Harness) {
    harness.runtime.pump_video(harness.clock.now_seconds()).expect("the pump runs");
}

#[test]
fn a_security_prompt_is_sent_to_the_phone_and_cleared_when_it_goes() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        set_notice(&harness, Some(security_prompt()));
        pump(&harness);

        let shown: NoticePayload = decode_json(&phone.next_of(MessageKind::Notice).await);
        assert_eq!(shown, security_prompt());

        set_notice(&harness, None);
        harness.clock.advance(1.0);
        pump(&harness);
        let cleared: NoticePayload = decode_json(&phone.next_of(MessageKind::Notice).await);
        assert_eq!(cleared.message, None);
    });
}

#[test]
fn a_standing_notice_is_not_repeated_on_every_pass() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        set_notice(&harness, Some(security_prompt()));
        for _ in 0..3 {
            pump(&harness);
            harness.clock.advance(1.0);
        }
        phone.next_of(MessageKind::Notice).await;
        let mut seen = 0;
        phone.send(peering_wire::framing::Frame::empty(MessageKind::Ping)).await;
        loop {
            let frame = phone.next().await;
            if frame.kind == MessageKind::Notice {
                seen += 1;
            }
            if frame.kind == MessageKind::Pong {
                break;
            }
        }
        assert_eq!(seen, 0);
    });
}

#[test]
fn a_phone_that_connects_during_a_security_prompt_is_told_about_it() {
    run(async {
        let harness = harness();
        let mut first = paired_phone(&harness.runtime).await;
        set_notice(&harness, Some(security_prompt()));
        pump(&harness);
        first.next_of(MessageKind::Notice).await;

        let mut second = reconnected_phone(&harness.runtime).await;
        let shown: NoticePayload = decode_json(&second.next_of(MessageKind::Notice).await);
        assert_eq!(shown, security_prompt());
    });
}

#[test]
fn a_capture_that_produces_no_frames_is_reported_once() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        harness.clock.advance(6.0);
        pump(&harness);

        let error: ErrorPayload = decode_json(&phone.next_of(MessageKind::Error).await);
        assert_eq!(error.code, "sourceUnavailable");

        harness.clock.advance(6.0);
        pump(&harness);
        phone.send(peering_wire::framing::Frame::empty(MessageKind::Ping)).await;
        loop {
            let frame = phone.next().await;
            assert_ne!(frame.kind, MessageKind::Error, "the report is sent once");
            if frame.kind == MessageKind::Pong {
                break;
            }
        }
    });
}

#[test]
fn a_security_prompt_explains_an_empty_picture_so_no_failure_is_reported() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        set_notice(&harness, Some(security_prompt()));
        harness.clock.advance(6.0);
        pump(&harness);

        phone.next_of(MessageKind::Notice).await;
        phone.send(peering_wire::framing::Frame::empty(MessageKind::Ping)).await;
        loop {
            let frame = phone.next().await;
            assert_ne!(frame.kind, MessageKind::Error);
            if frame.kind == MessageKind::Pong {
                break;
            }
        }
    });
}
