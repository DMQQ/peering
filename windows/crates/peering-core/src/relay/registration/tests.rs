use super::*;
use crate::fakes::clock::FakeClock;
use peering_wire::relay_messages::Token;

const UNIX_NOW: u64 = 1_700_000_000;

struct FakeSigner;

impl ProofSigner for FakeSigner {
    fn public_key(&self) -> Vec<u8> {
        vec![0x04, 0x01, 0x02]
    }

    fn sign(&self, _message: &[u8]) -> Vec<u8> {
        vec![0xAB, 0xCD]
    }
}

fn registration() -> RelayRegistration {
    RelayRegistration::new("device-1".to_owned(), "Studio Mac".to_owned(), 20, Box::new(FakeSigner))
}

fn clock() -> FakeClock {
    FakeClock::new(0.0, UNIX_NOW)
}

fn notification(tag: &str) -> RelayNotification {
    RelayNotification {
        device_token: tag.to_owned(),
        title: "Title".to_owned(),
        body: "Body".to_owned(),
        source: None,
        category: None,
        session_id: None,
        approval_id: None,
    }
}

fn sent_tokens(actions: &[RegAction]) -> Vec<String> {
    actions
        .iter()
        .filter_map(|action| match action {
            RegAction::Send(RelayClientMessage::NotifyDevice { device_token, .. }) => Some(device_token.clone()),
            _ => None,
        })
        .collect()
}

fn registered(registration: &mut RelayRegistration, clock: &FakeClock) {
    registration.start(clock);
    registration.on_message(RelayServerMessage::Registered { session_ttl_seconds: 300 }, clock);
}

/// Advances until the next tick produces something, and returns how long that took.
fn wait_for_connect(registration: &mut RelayRegistration, clock: &FakeClock) -> f64 {
    let begin = clock.now_seconds();
    loop {
        if registration.tick(clock) == vec![RegAction::Connect] {
            return clock.now_seconds() - begin;
        }
        clock.advance(0.25);
    }
}

#[test]
fn start_sends_the_host_registration_with_its_proof() {
    let mut registration = registration();
    let actions = registration.start(&clock());
    assert_eq!(
        actions,
        vec![RegAction::Send(RelayClientMessage::RegisterHost {
            device_id: "device-1".to_owned(),
            name: "Studio Mac".to_owned(),
            protocol_version: 20,
            public_key: Some("040102".to_owned()),
            proof: Some("abcd".to_owned()),
            proof_time: Some(UNIX_NOW),
        })]
    );
}

#[test]
fn notifications_are_held_until_the_relay_says_registered_and_then_sent_in_order() {
    let clock = clock();
    let mut registration = registration();
    registration.start(&clock);
    assert!(registration.notify_device(notification("a")).is_empty());
    assert!(registration.notify_device(notification("b")).is_empty());
    let flushed = registration.on_message(RelayServerMessage::Registered { session_ttl_seconds: 300 }, &clock);
    assert_eq!(sent_tokens(&flushed), ["a", "b"]);
}

#[test]
fn a_notification_is_sent_at_once_when_registered() {
    let clock = clock();
    let mut registration = registration();
    registered(&mut registration, &clock);
    assert_eq!(sent_tokens(&registration.notify_device(notification("now"))), ["now"]);
}

#[test]
fn the_held_queue_keeps_the_newest_sixteen() {
    let clock = clock();
    let mut registration = registration();
    registration.start(&clock);
    for index in 0..17 {
        registration.notify_device(notification(&index.to_string()));
    }
    let flushed = registration.on_message(RelayServerMessage::Registered { session_ttl_seconds: 300 }, &clock);
    let tokens = sent_tokens(&flushed);
    assert_eq!(tokens.len(), 16);
    assert_eq!(tokens.first().map(String::as_str), Some("1"));
    assert_eq!(tokens.last().map(String::as_str), Some("16"));
}

#[test]
fn requeued_notifications_go_ahead_of_newer_ones() {
    let clock = clock();
    let mut registration = registration();
    registered(&mut registration, &clock);
    registration.requeue(vec![notification("first"), notification("second")]);
    assert_eq!(sent_tokens(&registration.notify_device(notification("third"))), ["first", "second", "third"]);
}

#[test]
fn a_second_registered_message_does_not_send_the_queue_again() {
    let clock = clock();
    let mut registration = registration();
    registered(&mut registration, &clock);
    let again = registration.on_message(RelayServerMessage::Registered { session_ttl_seconds: 300 }, &clock);
    assert!(again.is_empty());
}

#[test]
fn a_registered_host_pings_every_twenty_five_seconds() {
    let clock = clock();
    let mut registration = registration();
    registered(&mut registration, &clock);
    clock.advance(24.9);
    assert!(registration.tick(&clock).is_empty());
    clock.advance(0.1);
    assert_eq!(registration.tick(&clock), vec![RegAction::Send(RelayClientMessage::Ping)]);
    registration.on_message(RelayServerMessage::Pong, &clock);
    clock.advance(24.9);
    assert!(registration.tick(&clock).is_empty());
    clock.advance(0.1);
    assert_eq!(registration.tick(&clock), vec![RegAction::Send(RelayClientMessage::Ping)]);
}

#[test]
fn nothing_is_pinged_before_the_relay_has_registered_the_host() {
    let clock = clock();
    let mut registration = registration();
    registration.start(&clock);
    clock.advance(49.0);
    assert!(registration.tick(&clock).is_empty());
}

#[test]
fn a_socket_that_says_nothing_for_two_ping_intervals_is_closed_and_reconnected() {
    let clock = clock();
    let mut registration = registration();
    registered(&mut registration, &clock);
    clock.advance(25.0);
    assert_eq!(registration.tick(&clock), vec![RegAction::Send(RelayClientMessage::Ping)]);
    clock.advance(24.9);
    assert!(registration.tick(&clock).is_empty());
    clock.advance(0.1);
    assert_eq!(registration.tick(&clock), vec![RegAction::Close]);
    assert!(!registration.is_registered());
    assert_eq!(wait_for_connect(&mut registration, &clock), 1.0);
}

#[test]
fn any_frame_from_the_relay_keeps_the_socket_alive() {
    let clock = clock();
    let mut registration = registration();
    registered(&mut registration, &clock);
    for _ in 0..4 {
        clock.advance(40.0);
        registration.note_frame(&clock);
        assert_ne!(registration.tick(&clock), vec![RegAction::Close]);
    }
}

#[test]
fn closing_a_silent_socket_and_then_reporting_the_disconnect_counts_one_loss() {
    let clock = clock();
    let mut registration = registration();
    registered(&mut registration, &clock);
    clock.advance(50.0);
    assert_eq!(registration.tick(&clock), vec![RegAction::Close]);
    registration.on_disconnect(&clock);
    assert_eq!(wait_for_connect(&mut registration, &clock), 1.0);
}

#[test]
fn a_clock_the_relay_refuses_is_reported_as_a_fault_until_a_registration_succeeds() {
    let clock = clock();
    let mut registration = registration();
    registration.start(&clock);
    assert_eq!(registration.fault(), None);
    let actions = registration.on_message(
        RelayServerMessage::Error { code: "proofStale".to_owned(), message: "old".to_owned() },
        &clock,
    );
    assert_eq!(actions, vec![RegAction::Close]);
    assert_eq!(registration.fault(), Some(RelayFault::ClockSkew));
    wait_for_connect(&mut registration, &clock);
    registration.start(&clock);
    assert_eq!(registration.fault(), Some(RelayFault::ClockSkew));
    registration.on_message(RelayServerMessage::Registered { session_ttl_seconds: 300 }, &clock);
    assert_eq!(registration.fault(), None);
}

#[test]
fn another_refusal_is_not_a_clock_fault() {
    let clock = clock();
    let mut registration = registration();
    registration.start(&clock);
    registration.on_message(RelayServerMessage::Error { code: "refused".to_owned(), message: "no".to_owned() }, &clock);
    assert_eq!(registration.fault(), None);
}

#[test]
fn a_session_ready_asks_for_the_session_to_be_dialled() {
    let clock = clock();
    let mut registration = registration();
    registered(&mut registration, &clock);
    let actions = registration.on_message(
        RelayServerMessage::SessionReady {
            control_host: "relay.example".to_owned(),
            control_port: 7000,
            video_host: "relay.example".to_owned(),
            video_port: 7001,
            control_token: Token([1; 16]),
            video_token: Token([2; 16]),
            remaining_seconds: None,
        },
        &clock,
    );
    assert_eq!(
        actions,
        vec![RegAction::DialSession(RelaySession {
            control_host: "relay.example".to_owned(),
            control_port: 7000,
            video_host: "relay.example".to_owned(),
            video_port: 7001,
            control_token: Token([1; 16]),
            video_token: Token([2; 16]),
        })]
    );
}

#[test]
fn an_error_closes_the_connection_and_reconnects_after_one_second() {
    let clock = clock();
    let mut registration = registration();
    registered(&mut registration, &clock);
    let actions = registration.on_message(
        RelayServerMessage::Error { code: "refused".to_owned(), message: "no".to_owned() },
        &clock,
    );
    assert_eq!(actions, vec![RegAction::Close]);
    assert_eq!(wait_for_connect(&mut registration, &clock), 1.0);
    assert!(registration.tick(&clock).is_empty());
}

#[test]
fn reconnect_delays_climb_one_two_five_ten_then_stay_at_thirty_seconds() {
    let clock = clock();
    let mut registration = registration();
    let mut gaps = Vec::new();
    for _ in 0..7 {
        registration.on_disconnect(&clock);
        gaps.push(wait_for_connect(&mut registration, &clock).round());
        registration.start(&clock);
    }
    assert_eq!(gaps, [1.0, 2.0, 5.0, 10.0, 30.0, 30.0, 30.0]);
}

#[test]
fn a_registration_that_drops_at_once_does_not_reset_the_ladder() {
    let clock = clock();
    let mut registration = registration();
    let mut gaps = Vec::new();
    for _ in 0..4 {
        registration.on_disconnect(&clock);
        gaps.push(wait_for_connect(&mut registration, &clock).round());
        registered(&mut registration, &clock);
        clock.advance(5.0);
    }
    assert_eq!(gaps, [1.0, 2.0, 5.0, 10.0]);
}

#[test]
fn a_registration_that_held_for_a_minute_resets_the_ladder() {
    let clock = clock();
    let mut registration = registration();
    for _ in 0..3 {
        registration.on_disconnect(&clock);
        wait_for_connect(&mut registration, &clock);
    }
    registered(&mut registration, &clock);
    for _ in 0..3 {
        clock.advance(20.0);
        registration.on_message(RelayServerMessage::Pong, &clock);
    }
    registration.on_disconnect(&clock);
    assert_eq!(wait_for_connect(&mut registration, &clock), 1.0);
}

#[test]
fn a_registration_that_held_for_less_than_a_minute_does_not_reset_the_ladder() {
    let clock = clock();
    let mut registration = registration();
    for _ in 0..2 {
        registration.on_disconnect(&clock);
        wait_for_connect(&mut registration, &clock);
    }
    registered(&mut registration, &clock);
    clock.advance(59.0);
    registration.on_disconnect(&clock);
    assert_eq!(wait_for_connect(&mut registration, &clock), 5.0);
}

#[test]
fn the_reconnect_wait_is_a_random_share_of_the_ladder_step() {
    let clock = clock();
    let mut registration = registration().with_jitter(Box::new(|| 0.5));
    registration.on_disconnect(&clock);
    assert_eq!(wait_for_connect(&mut registration, &clock), 0.5);
    registered(&mut registration, &clock);
    registration.on_disconnect(&clock);
    assert_eq!(wait_for_connect(&mut registration, &clock), 1.0);
}

#[test]
fn full_jitter_never_waits_less_than_a_quarter_second() {
    let clock = clock();
    let mut registration = registration().with_jitter(Box::new(|| 0.0));
    registration.on_disconnect(&clock);
    assert_eq!(wait_for_connect(&mut registration, &clock), 0.25);
}

#[test]
fn a_jitter_outside_the_unit_range_is_clamped() {
    let clock = clock();
    let mut registration = registration().with_jitter(Box::new(|| 7.0));
    registration.on_disconnect(&clock);
    assert_eq!(wait_for_connect(&mut registration, &clock), 1.0);
}

#[test]
fn each_attempt_signs_a_fresh_proof() {
    let clock = clock();
    let mut registration = registration();
    registration.on_disconnect(&clock);
    clock.advance(40.0);
    let actions = {
        wait_for_connect(&mut registration, &clock);
        registration.start(&clock)
    };
    let RegAction::Send(RelayClientMessage::RegisterHost { proof_time, .. }) = &actions[0] else {
        panic!("expected a registration, got {actions:?}");
    };
    assert_eq!(*proof_time, Some(UNIX_NOW + 40));
}

#[test]
fn notifications_raised_while_disconnected_wait_for_the_next_registration() {
    let clock = clock();
    let mut registration = registration();
    registered(&mut registration, &clock);
    registration.on_disconnect(&clock);
    assert!(registration.notify_device(notification("held")).is_empty());
    wait_for_connect(&mut registration, &clock);
    registration.start(&clock);
    let flushed = registration.on_message(RelayServerMessage::Registered { session_ttl_seconds: 300 }, &clock);
    assert_eq!(sent_tokens(&flushed), ["held"]);
}

#[test]
fn unknown_and_presence_messages_are_ignored() {
    let clock = clock();
    let mut registration = registration();
    registered(&mut registration, &clock);
    assert!(registration.on_message(RelayServerMessage::Unknown, &clock).is_empty());
    assert!(registration.on_message(RelayServerMessage::Pong, &clock).is_empty());
    let offline = RelayServerMessage::HostOffline { device_id: "device-1".to_owned() };
    assert!(registration.on_message(offline, &clock).is_empty());
}
