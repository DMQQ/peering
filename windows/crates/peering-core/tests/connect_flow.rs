//! A control connection from first byte to reaping: what a video socket may do, how long silence is tolerated,
//! and what counts as life.

mod common;

use std::sync::Arc;

use common::*;
use peering_core::fakes::input::RecordingInput;
use peering_core::ports::clock::Clock;
use peering_core::session::actions::SessionAction;
use peering_core::session::deps::PinStore;
use peering_core::session::dispatch::{on_ready_frame, ReadyOutcome};
use peering_core::session::handshake::HostSession;
use peering_core::session::liveness::{LivenessTracker, Verdict};
use peering_core::session::state::{HandshakeState, HostPhase};
use peering_wire::framing::{Frame, MessageKind};

fn ready_session(clock: Arc<dyn Clock>) -> HostSession {
    let pins: Arc<dyn PinStore> = Arc::new(MemoryPins::with_device(paired_device(&CLIENT_KEY)));
    let mut host = host_session(pins, Some(CLIENT_KEY.to_vec()), clock);
    host.on_frame(role_frame(CONTROL_ROLE));
    let actions = host.on_frame(PairingClient::new().hello());
    assert!(has_authorised(&actions));
    host
}

#[test]
fn a_video_socket_is_refused_when_no_control_session_has_been_authorised() {
    let mut host = host_session(Arc::new(MemoryPins::default()), Some(CLIENT_KEY.to_vec()), clock_at(0.0));

    let actions = host.on_frame(role_frame(VIDEO_ROLE));

    assert!(actions.contains(&SessionAction::VideoConnection));
    assert!(!has_authorised(&actions), "a video socket never authorises by itself");
    assert_eq!(host.state(), HandshakeState::Failed);
}

#[test]
fn a_connection_that_declared_video_stays_closed_to_the_control_handshake() {
    let mut host = host_session(Arc::new(MemoryPins::default()), Some(CLIENT_KEY.to_vec()), clock_at(0.0));
    host.on_frame(role_frame(VIDEO_ROLE));

    let hello = host.on_frame(PairingClient::new().hello());
    assert!(hello.is_empty(), "frames after a video role are not read as a control hello");
    assert_eq!(host.state(), HandshakeState::Failed);
    assert_eq!(host.client_id(), "");
}

#[test]
fn an_authorised_client_silent_for_sixty_seconds_is_reaped_but_not_at_the_limit() {
    let host = ready_session(clock_at(0.0));
    let tracker = LivenessTracker::started_at(0.0);

    assert_eq!(tracker.verdict(60.0, host.state().phase()), Verdict::Keep);
    assert_eq!(tracker.verdict(60.5, host.state().phase()), Verdict::End);
}

#[test]
fn an_unauthenticated_client_silent_for_thirty_seconds_is_reaped() {
    let mut host = host_session(Arc::new(MemoryPins::default()), Some(CLIENT_KEY.to_vec()), clock_at(0.0));
    host.on_frame(role_frame(CONTROL_ROLE));
    let tracker = LivenessTracker::started_at(0.0);
    assert_eq!(host.state().phase(), HostPhase::Unauthenticated);

    assert_eq!(tracker.verdict(30.0, host.state().phase()), Verdict::Keep);
    assert_eq!(tracker.verdict(30.5, host.state().phase()), Verdict::End);
}

#[test]
fn a_client_waiting_on_the_mac_user_gets_two_minutes_before_it_is_reaped() {
    let mut host = host_session(Arc::new(MemoryPins::default()), Some(CLIENT_KEY.to_vec()), clock_at(0.0));
    let mut phone = PairingClient::new();
    pair_up_to_code(&mut host, &mut phone);
    host.on_frame(phone.confirm(true, None));
    assert_eq!(host.state(), HandshakeState::AwaitingApproval);
    let tracker = LivenessTracker::started_at(0.0);

    assert_eq!(tracker.verdict(120.0, host.state().phase()), Verdict::Keep);
    assert_eq!(tracker.verdict(120.5, host.state().phase()), Verdict::End);
}

#[test]
fn any_inbound_frame_counts_as_life_even_when_it_is_not_a_ping() {
    let mut host = ready_session(clock_at(0.0));
    let mut tracker = LivenessTracker::started_at(0.0);
    let frames = [
        Frame::new(MessageKind::Command, br#"{"lockScreen":{}}"#.to_vec()),
        Frame::new(MessageKind::Ping, b"1".to_vec()),
        Frame::new(MessageKind::TextFocus, Vec::new()),
    ];
    let mut input = RecordingInput::default();
    let mut source = RecordingSource::default();
    let mut now = 0.0;
    for frame in frames {
        now += 50.0;
        host.on_frame(frame.clone());
        tracker.heard(now);
        let mut ctx = dispatch_context(&mut input, &mut source, false);
        let _ = on_ready_frame(&frame, &mut ctx);
        assert_eq!(tracker.verdict(now + 59.0, host.state().phase()), Verdict::Keep);
    }
    assert_eq!(tracker.verdict(now + 60.5, host.state().phase()), Verdict::End);
}

#[test]
fn a_ping_from_a_ready_client_is_answered_with_a_pong_echoing_its_payload() {
    let host = ready_session(clock_at(0.0));
    assert_eq!(host.state(), HandshakeState::Ready);
    let ping = Frame::new(MessageKind::Ping, b"{\"sequence\":42}".to_vec());
    let mut input = RecordingInput::default();
    let mut source = RecordingSource::default();
    let mut ctx = dispatch_context(&mut input, &mut source, false);

    let outcome = on_ready_frame(&ping, &mut ctx);

    assert_eq!(outcome, ReadyOutcome::Reply(Frame::new(MessageKind::Pong, b"{\"sequence\":42}".to_vec())));
    assert!(input.applied().is_empty());
    assert!(source.sources.is_empty());
}
