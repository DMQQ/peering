//! Requests a phone makes on its control connection: lock the workstation, change the frame rate without a reconnect, and
//! pause and resume the picture. The lock is advertised in the hello only when the workstation can be locked.

mod support;

use peering_core::fakes::system::RecordingSystem;
use peering_core::ports::capture::RawFrame;
use peering_core::ports::clock::Clock;
use peering_wire::command::RemoteCommand;
use peering_wire::framing::{Frame, MessageKind};
use support::*;

#[test]
fn a_lock_request_locks_the_workstation_once() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        phone.send_command(&RemoteCommand::LockScreen {}).await;
        phone.sync().await;
        assert_eq!(harness.system.lock().expect("the system is not poisoned").lock_calls(), 1);
    });
}

#[test]
fn the_hello_advertises_the_lock_when_the_workstation_can_be_locked() {
    run(async {
        let harness = harness();
        let hello = server_hello_for(&harness).await;
        assert_eq!(hello.capabilities.supports_lock_screen, Some(true));
    });
}

#[test]
fn the_hello_does_not_advertise_a_lock_the_workstation_cannot_do() {
    run(async {
        let harness = harness_with_system(RecordingSystem::new(false, None));
        let hello = server_hello_for(&harness).await;
        assert_eq!(hello.capabilities.supports_lock_screen, None);
    });
}

#[test]
fn the_hello_advertises_chat_and_the_session_list_when_the_agent_cli_is_installed() {
    run(async {
        let harness = harness();
        let hello = server_hello_for(&harness).await;
        assert_eq!(hello.capabilities.supports_agent_chat, Some(true));
        assert_eq!(hello.capabilities.supports_agent_list, Some(true));
        assert_eq!(hello.agent_chat_agents, Some(vec!["claude".to_owned()]));
    });
}

#[test]
fn the_hello_does_not_advertise_chat_without_the_agent_cli() {
    run(async {
        let harness = harness_without_agent_cli();
        let hello = server_hello_for(&harness).await;
        assert_eq!(hello.capabilities.supports_agent_chat, None);
        assert_eq!(hello.capabilities.supports_agent_list, None);
        assert_eq!(hello.agent_chat_agents, None);
        assert_eq!(hello.capabilities.supports_file_browser, Some(true), "browsing files does not need the CLI");
    });
}

#[test]
fn a_frame_rate_request_reconfigures_the_encoder_on_the_same_connection() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        phone.send_command(&select_display_command()).await;
        phone.send_command(&RemoteCommand::SetStreamQuality { fps: 30, bitrate_kbps: 0 }).await;
        phone.sync().await;
        push_and_pump(&harness, 1);
        phone.next_of(MessageKind::VideoConfig).await;
        let configured = harness.encoder.lock().expect("the encoder is not poisoned").configure_calls().last().copied();
        assert_eq!(configured.map(|(_, _, fps, _)| fps), Some(30));
        phone.sync().await;
    });
}

#[test]
fn pausing_the_picture_stops_it_and_resuming_sends_the_config_and_a_keyframe() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        phone.send_command(&select_display_command()).await;
        phone.sync().await;
        push_and_pump(&harness, 1);
        phone.next_of(MessageKind::VideoFrame).await;

        phone.send_command(&RemoteCommand::SetVideoEnabled { enabled: false }).await;
        phone.sync().await;
        push_and_pump(&harness, 2);
        phone.send(Frame::empty(MessageKind::Ping)).await;
        let next = phone.next().await;
        assert_eq!(next.kind, MessageKind::Pong, "no picture arrives while paused");

        phone.send_command(&RemoteCommand::SetVideoEnabled { enabled: true }).await;
        phone.sync().await;
        push_and_pump(&harness, 3);
        phone.next_of(MessageKind::VideoConfig).await;
        let resumed = phone.next_of(MessageKind::VideoFrame).await;
        assert!(keyframe_flag(&resumed), "the first picture after a resume is a keyframe");
    });
}

fn push_and_pump(harness: &Harness, sequence: u64) {
    harness.capture.lock().expect("the capture is not poisoned").push_frame(RawFrame { width: 1920, height: 1080, sequence });
    harness.runtime.pump_video(harness.clock.now_seconds()).expect("the pump runs");
}

fn keyframe_flag(frame: &Frame) -> bool {
    frame.payload.first().is_some_and(|flags| flags & 1 == 1)
}

async fn server_hello_for(harness: &Harness) -> peering_wire::handshake::ServerHello {
    let mut phone = Phone::connect(&harness.runtime, direct_peer());
    phone.send(role_frame(CONTROL_ROLE)).await;
    phone.send(hello()).await;
    server_hello(&phone.next_of(MessageKind::ServerHello).await)
}
