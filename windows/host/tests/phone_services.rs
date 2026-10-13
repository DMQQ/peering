//! What a phone gets from the PC around the picture: its clipboard, a PC that stays awake, the addresses to wake it, the
//! pointer, and an answer to everything it asks that the host will not do.

mod support;

use peering_core::ports::clipboard::Clipboard;
use peering_core::fakes::system::RecordingSystem;
use peering_core::ports::clipboard::{ClipboardContent, ClipboardError};
use peering_core::ports::clock::Clock;
use peering_wire::chunks::{self, Reassembler, CONTROL_CHUNK_SIZE};
use peering_wire::clipboard::{ClipboardKind, ClipboardPayload};
use peering_wire::command::RemoteCommand;
use peering_wire::framing::{Frame, MessageKind};
use peering_wire::handshake::{ClientCapabilities, NoticePayload};
use peering_wire::source::NormalizedPoint;
use support::*;

fn declaring_images() -> ClientCapabilities {
    ClientCapabilities { supports_clipboard_images: Some(true), ..ClientCapabilities::default() }
}

fn declaring_pointer() -> ClientCapabilities {
    ClientCapabilities { supports_pointer_report: Some(true), ..ClientCapabilities::default() }
}

async fn pair_and_leave(harness: &Harness) {
    drop(paired_phone(&harness.runtime).await);
}

async fn clipboard_answer(phone: &mut Phone) -> ClipboardPayload {
    phone.send_command(&RemoteCommand::RequestClipboard {}).await;
    let first = phone.next_of_either(&[MessageKind::ClipboardContent, MessageKind::VideoChunk]).await;
    if first.kind == MessageKind::ClipboardContent {
        return decode_json(&first);
    }
    let mut reassembler = Reassembler::new(peering_wire::clipboard::MAX_REASSEMBLED_BYTES);
    let mut frame = first;
    loop {
        if let Some(whole) = reassembler.ingest(&frame).expect("a chunk") {
            return decode_json(&whole);
        }
        frame = phone.next_of(MessageKind::VideoChunk).await;
    }
}

#[test]
fn a_clipboard_request_is_answered_with_the_text_on_the_pc() {
    run(async {
        let harness = harness();
        harness.clipboard.write(&ClipboardContent::Text("copied on the PC".to_owned())).expect("the fake clipboard takes it");
        let mut phone = paired_phone(&harness.runtime).await;
        assert_eq!(clipboard_answer(&mut phone).await, ClipboardPayload::text("copied on the PC"));
    });
}

#[test]
fn a_clipboard_request_is_answered_with_empty_text_when_there_is_nothing_to_give() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        assert_eq!(clipboard_answer(&mut phone).await, ClipboardPayload::text(""));
        harness.clipboard.fail_with(ClipboardError::Busy);
        assert_eq!(clipboard_answer(&mut phone).await, ClipboardPayload::text(""));
    });
}

#[test]
fn a_picture_is_sent_only_to_a_phone_that_declared_it_can_read_one() {
    run(async {
        let harness = harness();
        pair_and_leave(&harness).await;
        harness.clipboard.write(&ClipboardContent::Image(vec![1, 2, 3])).expect("the fake clipboard takes it");

        let mut without = reconnected_phone_declaring(&harness.runtime, ClientCapabilities::default()).await;
        assert_eq!(clipboard_answer(&mut without).await, ClipboardPayload::text(""));
        drop(without);

        let mut with = reconnected_phone_declaring(&harness.runtime, declaring_images()).await;
        let answer = clipboard_answer(&mut with).await;
        assert_eq!(answer.kind, ClipboardKind::Image);
        assert_eq!(answer.image, Some(vec![1, 2, 3]));
    });
}

#[test]
fn a_long_clipboard_text_arrives_in_chunks_that_make_the_original() {
    run(async {
        let harness = harness();
        let text = "line of text\n".repeat(20_000);
        harness.clipboard.write(&ClipboardContent::Text(text.clone())).expect("the fake clipboard takes it");
        let mut phone = paired_phone(&harness.runtime).await;
        assert_eq!(clipboard_answer(&mut phone).await, ClipboardPayload::text(text));
    });
}

#[test]
fn pushed_text_lands_on_the_pc_clipboard_before_the_next_command_runs() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        phone.send_command(&RemoteCommand::PushClipboard { text: "from the phone".to_owned() }).await;
        phone.sync().await;
        assert_eq!(harness.clipboard.current(), Some(ClipboardContent::Text("from the phone".to_owned())));
    });
}

#[test]
fn pushed_text_too_large_for_one_frame_arrives_in_chunks_and_lands_whole() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        let text = "0123456789".repeat(30_000);
        let command = serde_json::to_vec(&RemoteCommand::PushClipboard { text: text.clone() }).expect("a command serialises");
        for frame in chunks::encode(MessageKind::Command, &command, 5, CONTROL_CHUNK_SIZE) {
            phone.send(frame).await;
        }
        phone.sync().await;
        assert_eq!(harness.clipboard.current(), Some(ClipboardContent::Text(text)));
    });
}

#[test]
fn a_pushed_picture_lands_on_the_clipboard() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        phone.send_command(&RemoteCommand::PushClipboardImage { png: vec![9, 9, 9] }).await;
        phone.sync().await;
        assert_eq!(harness.clipboard.current(), Some(ClipboardContent::Image(vec![9, 9, 9])));
    });
}

#[test]
fn a_clipboard_that_cannot_be_written_is_said_aloud_and_lapses() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        harness.clipboard.fail_with(ClipboardError::Busy);
        phone.send_command(&RemoteCommand::PushClipboard { text: "lost".to_owned() }).await;
        phone.sync().await;
        pump(&harness);
        let shown: NoticePayload = decode_json(&phone.next_of(MessageKind::Notice).await);
        assert!(shown.message.is_some());
        harness.clock.advance(7.0);
        pump(&harness);
        let cleared: NoticePayload = decode_json(&phone.next_of(MessageKind::Notice).await);
        assert_eq!(cleared.message, None);
    });
}

fn pump(harness: &Harness) {
    harness.runtime.pump_video(harness.clock.now_seconds()).expect("the pump runs");
}

#[test]
fn privacy_mode_is_refused_with_the_code_the_iphone_words_and_lapses() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        phone.send_command(&RemoteCommand::SetPrivacyMode { enabled: true }).await;
        phone.sync().await;
        pump(&harness);
        let shown: NoticePayload = decode_json(&phone.next_of(MessageKind::Notice).await);
        assert_eq!(shown.code.as_deref(), Some("privacyModeFailed"));
        harness.clock.advance(7.0);
        pump(&harness);
        let cleared: NoticePayload = decode_json(&phone.next_of(MessageKind::Notice).await);
        assert_eq!(cleared.message, None);
    });
}

#[test]
fn switching_privacy_mode_off_says_nothing() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        phone.send_command(&RemoteCommand::SetPrivacyMode { enabled: false }).await;
        phone.sync().await;
        pump(&harness);
        phone.sync().await;
        assert!(harness.runtime.snapshot().connected_clients == 1);
    });
}

async fn refusal_for(command: RemoteCommand) -> NoticePayload {
    let harness = harness();
    let mut phone = paired_phone(&harness.runtime).await;
    phone.send_command(&command).await;
    phone.sync().await;
    pump(&harness);
    decode_json(&phone.next_of(MessageKind::Notice).await)
}

#[test]
fn a_desktop_switch_is_refused_in_words() {
    run(async {
        let shown = refusal_for(RemoteCommand::SwitchSpace { direction: peering_wire::command::SpaceDirection::Left }).await;
        assert!(shown.message.is_some());
    });
}

#[test]
fn an_app_launch_is_refused_in_words() {
    run(async {
        let shown = refusal_for(RemoteCommand::LaunchApplication { bundle_identifier: "notepad".to_owned() }).await;
        assert!(shown.message.is_some());
    });
}

#[test]
fn a_window_action_is_refused_in_words() {
    run(async {
        let shown = refusal_for(RemoteCommand::PerformWindowAction {
            window_id: 7,
            action: peering_wire::command::WindowAction::Close,
        })
        .await;
        assert!(shown.message.is_some());
    });
}

#[test]
fn a_source_the_host_cannot_capture_is_a_notice_and_not_an_error_that_ends_the_session() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        phone.send_command(&RemoteCommand::SetCaptureSource { source: peering_wire::source::CaptureSource::Window { id: 77 } }).await;
        phone.sync().await;
        pump(&harness);
        let shown: NoticePayload = decode_json(&phone.next_of(MessageKind::Notice).await);
        assert_eq!(shown.code.as_deref(), Some("displayDisconnected"));
        phone.sync().await;
    });
}

#[test]
fn a_web_preview_request_is_answered_so_the_page_stops_waiting() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        let request = br#"{"fetch":{"_0":{"id":42,"port":3000,"method":"GET","target":"/","headers":[]}}}"#;
        phone.send(Frame::new(MessageKind::PreviewRequest, request.to_vec())).await;
        let answer: serde_json::Value = decode_json(&phone.next_of(MessageKind::PreviewEvent).await);
        assert_eq!(answer, serde_json::json!({ "failure": { "id": 42, "reason": "notAllowed" } }));
    });
}

#[test]
fn a_live_activity_token_is_ignored_and_the_connection_stays_open() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        phone.send(Frame::new(MessageKind::ActivityToken, br#"{"activity":"session","pushToken":null,"pushToStartToken":null,"environment":"sandbox"}"#.to_vec())).await;
        phone.sync().await;
    });
}

#[test]
fn the_pc_is_kept_awake_while_a_phone_is_connected_and_released_when_it_leaves() {
    run(async {
        let harness = harness();
        let calls = || harness.system.lock().expect("the system is not poisoned").keep_awake_calls().to_vec();
        assert!(calls().is_empty());
        let phone = paired_phone(&harness.runtime).await;
        assert_eq!(calls(), [true]);
        drop(phone);
        until(|| (calls() == [true, false]).then_some(())).await;
    });
}

#[test]
fn hosting_being_switched_off_lets_the_pc_sleep_again() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        harness.runtime.start_pump();
        assert!(harness.runtime.handle().send(peering_host::runtime::RuntimeCommand::SetHosting(false)));
        while phone.try_next().await.is_some() {}
        let released = || harness.system.lock().expect("the system is not poisoned").keep_awake_calls().to_vec();
        until(|| (released() == [true, false]).then_some(())).await;
    });
}

#[test]
fn a_paired_phone_is_given_the_addresses_to_wake_the_pc() {
    run(async {
        let harness = harness_with_system(RecordingSystem::new(true, None).with_hardware_addresses(&["aa:bb:cc:dd:ee:ff"]));
        pair_and_leave(&harness).await;
        let hello = paired_server_hello(&harness.runtime).await;
        assert_eq!(hello.mac_addresses, Some(vec!["aa:bb:cc:dd:ee:ff".to_owned()]));
    });
}

#[test]
fn a_phone_that_is_not_paired_is_given_no_addresses() {
    run(async {
        let harness = harness_with_system(RecordingSystem::new(true, None).with_hardware_addresses(&["aa:bb:cc:dd:ee:ff"]));
        let mut phone = Phone::connect(&harness.runtime, direct_peer());
        phone.send(role_frame(CONTROL_ROLE)).await;
        phone.send(hello()).await;
        assert_eq!(server_hello(&phone.next_of(MessageKind::ServerHello).await).mac_addresses, None);
    });
}

fn set_pointer(harness: &Harness, position: (f64, f64)) {
    harness.input.lock().expect("the input is not poisoned").set_pointer(Some(position));
}

#[test]
fn a_hand_on_the_mouse_is_reported_to_a_phone_that_asked() {
    run(async {
        let harness = harness();
        pair_and_leave(&harness).await;
        let mut phone = reconnected_phone_declaring(&harness.runtime, declaring_pointer()).await;
        set_pointer(&harness, (100.0, 100.0));
        harness.runtime.pump_pointer(harness.clock.now_seconds());
        set_pointer(&harness, (960.0, 540.0));
        harness.runtime.pump_pointer(harness.clock.now_seconds() + 0.1);
        let point: NormalizedPoint = decode_json(&phone.next_of(MessageKind::PointerReport).await);
        assert_eq!((point.x, point.y), (0.375, 0.375));
    });
}

#[test]
fn a_phone_that_did_not_ask_is_not_sent_the_pointer() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        set_pointer(&harness, (100.0, 100.0));
        harness.runtime.pump_pointer(0.0);
        set_pointer(&harness, (960.0, 540.0));
        harness.runtime.pump_pointer(0.1);
        phone.send(Frame::empty(MessageKind::Ping)).await;
        loop {
            let frame = phone.next().await;
            assert_ne!(frame.kind, MessageKind::PointerReport);
            if frame.kind == MessageKind::Pong {
                break;
            }
        }
    });
}

#[test]
fn the_pointer_a_joystick_left_is_reported_after_it_settles() {
    run(async {
        let harness = harness();
        pair_and_leave(&harness).await;
        let mut phone = reconnected_phone_declaring(&harness.runtime, declaring_pointer()).await;
        set_pointer(&harness, (100.0, 100.0));
        harness.runtime.pump_pointer(10.0);
        set_pointer(&harness, (960.0, 540.0));
        phone.send_command(&RemoteCommand::JoystickMove { dx: 5.0, dy: 5.0 }).await;
        phone.sync().await;
        harness.runtime.pump_pointer(10.1);
        harness.runtime.pump_pointer(10.5);
        let point: NormalizedPoint = decode_json(&phone.next_of(MessageKind::PointerReport).await);
        assert_eq!((point.x, point.y), (0.375, 0.375));
    });
}
