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
fn a_video_connection_is_kept_however_long_it_is_silent() {
    let tracker = LivenessTracker::started_at(0.0);
    assert_eq!(tracker.verdict_for(3600.0, HostPhase::Unauthenticated, true), Verdict::Keep);
    assert_eq!(tracker.verdict_for(3600.0, HostPhase::Unauthenticated, false), Verdict::End);
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

#[test]
fn a_backgrounded_authorised_session_is_given_three_minutes() {
    let mut tracker = LivenessTracker::started_at(0.0);
    tracker.set_background(true);
    assert_eq!(tracker.verdict(BACKGROUND_SILENCE_SECONDS, HostPhase::Authorized), Verdict::Keep);
    assert_eq!(tracker.verdict(BACKGROUND_SILENCE_SECONDS + 0.5, HostPhase::Authorized), Verdict::End);
}

#[test]
fn returning_to_the_foreground_restores_the_sixty_second_limit() {
    let mut tracker = LivenessTracker::started_at(0.0);
    tracker.set_background(true);
    tracker.set_background(false);
    assert_eq!(tracker.verdict(AUTHORISED_SILENCE_SECONDS + 0.5, HostPhase::Authorized), Verdict::End);
}

#[test]
fn the_background_flag_does_not_stretch_the_limits_before_authorisation() {
    let mut tracker = LivenessTracker::started_at(0.0);
    tracker.set_background(true);
    assert_eq!(tracker.verdict(UNAUTHENTICATED_SILENCE_SECONDS + 0.5, HostPhase::Unauthenticated), Verdict::End);
}

#[test]
fn a_session_that_keeps_pinging_while_awaiting_approval_is_ended_at_the_absolute_limit() {
    let clock = FakeClock::new(0.0, 0);
    let mut tracker = tracker_at_clock_start(&clock);
    tracker.note_phase(HostPhase::AwaitingApproval, clock.now_seconds());
    for _ in 0..24 {
        clock.advance(5.0);
        tracker.heard(clock.now_seconds());
        tracker.note_phase(HostPhase::AwaitingApproval, clock.now_seconds());
    }
    assert_eq!(tracker.verdict(clock.now_seconds(), HostPhase::AwaitingApproval), Verdict::Keep, "exactly 120 s is allowed");
    clock.advance(1.0);
    tracker.heard(clock.now_seconds());
    assert_eq!(tracker.verdict(clock.now_seconds(), HostPhase::AwaitingApproval), Verdict::End);
}

#[test]
fn leaving_the_approval_wait_forgets_how_long_it_lasted() {
    let clock = FakeClock::new(0.0, 0);
    let mut tracker = tracker_at_clock_start(&clock);
    tracker.note_phase(HostPhase::AwaitingApproval, clock.now_seconds());
    clock.advance(100.0);
    tracker.note_phase(HostPhase::Authorized, clock.now_seconds());
    clock.advance(100.0);
    tracker.heard(clock.now_seconds());
    assert_eq!(tracker.verdict(clock.now_seconds(), HostPhase::Authorized), Verdict::Keep);
}
