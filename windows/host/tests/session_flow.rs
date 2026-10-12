mod support;

use peering_core::ports::capture::RawFrame;
use peering_core::ports::clock::Clock;
use peering_host::runtime::PeerInfo;
use peering_wire::framing::MessageKind;
use peering_wire::source::CaptureCatalog;
use peering_wire::command::RemoteCommand;
use support::*;

#[test]
fn an_authorised_phone_gets_the_catalogue_then_a_video_config_and_a_frame() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        let catalogue: CaptureCatalog = decode_json(&phone.next_of(MessageKind::Catalog).await);
        assert_eq!(catalogue.displays.len(), 1);

        phone.send_command(&select_display_command()).await;
        phone.sync().await;
        harness
            .capture
            .lock()
            .expect("the capture is not poisoned")
            .push_frame(RawFrame { width: 1920, height: 1080, sequence: 1 });
        harness.runtime.pump_video(harness.clock.now_seconds()).expect("the pump runs");

        let config = phone.next_of(MessageKind::VideoConfig).await;
        let picture = phone.next_of(MessageKind::VideoFrame).await;
        assert!(!config.payload.is_empty());
        assert!(!picture.payload.is_empty());
    });
}

#[test]
fn a_relayed_phone_gets_video_on_its_control_connection() {
    run(async {
        let harness = harness();
        let peer = PeerInfo { via_relay: true, video_token: Some([9; 16]), ..direct_peer() };
        let (mut phone, result, _offer) = pair_with_peer(&harness.runtime, peer, |client, secret| client.proof(secret)).await;
        assert!(result.accepted);
        phone.send_command(&select_display_command()).await;
        phone.sync().await;
        harness
            .capture
            .lock()
            .expect("the capture is not poisoned")
            .push_frame(RawFrame { width: 1280, height: 720, sequence: 1 });
        harness.runtime.pump_video(harness.clock.now_seconds()).expect("the pump runs");
        phone.next_of(MessageKind::VideoConfig).await;
    });
}

#[test]
fn a_mouse_move_from_the_phone_reaches_the_input() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        phone.send_command(&mouse_move(0.25, 0.75)).await;
        phone.sync().await;
        let input = harness.input.lock().expect("the input is not poisoned");
        assert!(input
            .applied()
            .iter()
            .any(|(command, _)| matches!(command, RemoteCommand::MouseMove { .. })));
    });
}

#[test]
fn a_folder_listing_request_is_answered_from_the_file_system() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        phone
            .send_json(MessageKind::TerminalRequest, &peering_wire::terminal::TerminalRequest::StartBrowser { id: "browse-1".to_owned() })
            .await;
        let request = peering_wire::terminal::TerminalRequest::ListDirectory {
            session_id: "browse-1".to_owned(),
            path: Some("/C:/Users/me".to_owned()),
        };
        phone.send_json(MessageKind::TerminalRequest, &request).await;
        let event = phone.next_of(MessageKind::TerminalEvent).await;
        assert!(String::from_utf8_lossy(&event.payload).contains("notes.txt"));
    });
}

#[test]
fn a_video_connection_without_an_authorised_control_session_is_refused() {
    run(async {
        let harness = harness();
        let mut phone = Phone::connect(&harness.runtime, direct_peer());
        phone.send(role_frame(VIDEO_ROLE)).await;
        assert!(phone.try_next().await.is_none());
    });
}
