use super::*;
use crate::fakes::clock::FakeClock;
use crate::ports::clock::Clock;

fn tracker_at_clock_start(clock: &FakeClock) -> LivenessTracker {
    LivenessTracker::started_at(clock.now_seconds())
}

#[test]
fn authorised_session_is_kept_at_exactly_the_limit_and_ended_just_past_it() {
    let clock = FakeClock::new(0.0, 0);
    let tracker = tracker_at_clock_start(&clock);
    clock.advance(AUTHORISED_SILENCE_SECONDS);
    assert_eq!(tracker.verdict(clock.now_seconds(), HostPhase::Authorized), Verdict::Keep);
    clock.advance(0.5);
    assert_eq!(tracker.verdict(clock.now_seconds(), HostPhase::Authorized), Verdict::End);
}

#[test]
fn unauthenticated_session_has_the_shorter_thirty_second_limit() {
    let clock = FakeClock::new(0.0, 0);
    let tracker = tracker_at_clock_start(&clock);
    clock.advance(UNAUTHENTICATED_SILENCE_SECONDS);
    assert_eq!(tracker.verdict(clock.now_seconds(), HostPhase::Unauthenticated), Verdict::Keep);
    clock.advance(0.5);
    assert_eq!(tracker.verdict(clock.now_seconds(), HostPhase::Unauthenticated), Verdict::End);
}

#[test]
fn session_awaiting_approval_is_given_two_minutes() {
    let clock = FakeClock::new(0.0, 0);
    let tracker = tracker_at_clock_start(&clock);
    clock.advance(119.0);
    assert_eq!(tracker.verdict(clock.now_seconds(), HostPhase::AwaitingApproval), Verdict::Keep);
    clock.advance(2.0);
    assert_eq!(tracker.verdict(clock.now_seconds(), HostPhase::AwaitingApproval), Verdict::End);
}

#[test]
fn a_frame_restarts_the_silence() {
    let clock = FakeClock::new(0.0, 0);
    let mut tracker = tracker_at_clock_start(&clock);
    clock.advance(50.0);
    tracker.heard(clock.now_seconds());
    clock.advance(55.0);
    assert_eq!(tracker.verdict(clock.now_seconds(), HostPhase::Authorized), Verdict::Keep);
    clock.advance(6.0);
    assert_eq!(tracker.verdict(clock.now_seconds(), HostPhase::Authorized), Verdict::End);
}

#[test]
fn the_same_silence_ends_an_unauthenticated_session_but_not_an_authorised_one() {
    let clock = FakeClock::new(0.0, 0);
    let tracker = tracker_at_clock_start(&clock);
    clock.advance(45.0);
    assert_eq!(tracker.verdict(clock.now_seconds(), HostPhase::Unauthenticated), Verdict::End);
    assert_eq!(tracker.verdict(clock.now_seconds(), HostPhase::Authorized), Verdict::Keep);
}

#[test]
fn pong_echoes_the_ping_payload_with_the_pong_kind() {
    let ping = Frame::new(MessageKind::Ping, b"{\"sequence\":9}".to_vec());
    let pong = pong_for(&ping);
    assert_eq!(pong.kind, MessageKind::Pong);
    assert_eq!(pong.payload, ping.payload);
}

#[test]
fn an_empty_ping_from_an_old_client_gets_an_empty_pong() {
    let pong = pong_for(&Frame::empty(MessageKind::Ping));
    assert_eq!(pong, Frame::empty(MessageKind::Pong));
}

#[test]
fn a_ping_does_not_keep_an_unauthenticated_connection_alive() {
    assert!(!counts_as_life(HostPhase::Unauthenticated, MessageKind::Ping));
    assert!(!counts_as_life(HostPhase::Unauthenticated, MessageKind::Command));
}

#[test]
fn handshake_frames_count_before_authorisation() {
    for kind in [MessageKind::ConnectionRole, MessageKind::ClientHello, MessageKind::PairCommit, MessageKind::PairReveal, MessageKind::PairConfirm] {
        assert!(counts_as_life(HostPhase::Unauthenticated, kind), "{kind:?}");
    }
}

#[test]
fn a_client_awaiting_approval_is_kept_by_pings_only() {
    assert!(counts_as_life(HostPhase::AwaitingApproval, MessageKind::Ping));
    assert!(!counts_as_life(HostPhase::AwaitingApproval, MessageKind::Command));
}

#[test]
fn every_frame_counts_once_authorised() {
    assert!(counts_as_life(HostPhase::Authorized, MessageKind::Command));
    assert!(counts_as_life(HostPhase::Authorized, MessageKind::Ping));
}
