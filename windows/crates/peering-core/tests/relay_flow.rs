//! The host's registration with the relay: what it sends, when it pings, how it reconnects, and how a ready session
//! is dialled. No sockets; time comes from the fake clock.

mod common;

use common::{relay_token, UNIX_NOW};
use peering_core::fakes::clock::FakeClock;
use peering_core::fakes::stream::LoopbackStream;
use peering_core::ports::clock::Clock;
use peering_core::ports::stream::ByteStream;
use peering_core::relay::dial::{self, DialError, RelayControlStream};
use peering_core::relay::registration::{RegAction, RelayNotification, RelayRegistration, RelaySession};
use peering_wire::relay_messages::{RelayClientMessage, RelayServerMessage};
use peering_wire::relay_messages::Token;
use peering_wire::relay_proof::ProofSigner;
use peering_wire::sealing::TOKEN_SIZE;

struct StaticSigner;

impl ProofSigner for StaticSigner {
    fn public_key(&self) -> Vec<u8> {
        vec![0x04; 65]
    }

    fn sign(&self, message: &[u8]) -> Vec<u8> {
        message.to_vec()
    }
}

fn registration() -> RelayRegistration {
    RelayRegistration::new(
        "HOST-DEVICE".to_owned(),
        "Studio PC".to_owned(),
        20,
        Box::new(StaticSigner),
    )
}

/// Opens the link the way the caller does: the first disconnect schedules the connect, a tick reaches it, and the
/// caller reports the connection open.
fn open_link(reg: &mut RelayRegistration, clock: &FakeClock) -> Vec<RegAction> {
    reg.on_disconnect(clock);
    clock.advance(1.0);
    assert_eq!(reg.tick(clock), vec![RegAction::Connect]);
    reg.start(clock)
}

fn registered(reg: &mut RelayRegistration, clock: &FakeClock) {
    open_link(reg, clock);
    reg.on_message(RelayServerMessage::Registered { session_ttl_seconds: 300 }, clock);
    assert!(reg.is_registered());
}

fn relay_session() -> RelaySession {
    RelaySession {
        control_host: "relay.example".to_owned(),
        control_port: 4433,
        video_host: "relay.example".to_owned(),
        video_port: 4434,
        control_token: relay_token(),
        video_token: Token::parse("ffeeddccbbaa99887766554433221100").expect("a 32 digit token"),
    }
}

fn notification(title: &str) -> RelayNotification {
    RelayNotification {
        device_token: "device-token".to_owned(),
        title: title.to_owned(),
        body: String::new(),
        source: None,
        category: None,
        session_id: None,
        approval_id: None,
    }
}

fn seconds_until_connect(reg: &mut RelayRegistration, clock: &FakeClock) -> f64 {
    let mut elapsed = 0.0;
    loop {
        if reg.tick(clock) == vec![RegAction::Connect] {
            return elapsed;
        }
        clock.advance(0.5);
        elapsed += 0.5;
        assert!(elapsed < 60.0, "no reconnect was scheduled");
    }
}

#[test]
fn the_host_registers_with_a_fresh_signed_proof_once_the_link_opens() {
    let clock = FakeClock::new(0.0, UNIX_NOW);
    let mut reg = registration();

    let actions = open_link(&mut reg, &clock);

    let [RegAction::Send(RelayClientMessage::RegisterHost { device_id, name, protocol_version, public_key, proof, proof_time })] =
        actions.as_slice()
    else {
        panic!("expected one registration, got {actions:?}");
    };
    assert_eq!(device_id, "HOST-DEVICE");
    assert_eq!(name, "Studio PC");
    assert_eq!(*protocol_version, 20);
    assert!(public_key.is_some() && proof.is_some());
    assert_eq!(*proof_time, Some(clock.unix_seconds()));
    assert!(!reg.is_registered(), "registered only after the relay says so");
}

#[test]
fn a_registered_host_pings_the_relay_every_twenty_five_seconds() {
    let clock = FakeClock::new(0.0, UNIX_NOW);
    let mut reg = registration();
    registered(&mut reg, &clock);

    clock.advance(24.9);
    assert!(reg.tick(&clock).is_empty());
    clock.advance(0.1);
    assert_eq!(reg.tick(&clock), vec![RegAction::Send(RelayClientMessage::Ping)]);
    reg.on_message(RelayServerMessage::Pong, &clock);
    clock.advance(24.9);
    assert!(reg.tick(&clock).is_empty());
    clock.advance(0.1);
    assert_eq!(reg.tick(&clock), vec![RegAction::Send(RelayClientMessage::Ping)]);
}

#[test]
fn reconnects_wait_one_two_five_ten_then_thirty_seconds_and_stay_at_thirty() {
    let clock = FakeClock::new(0.0, UNIX_NOW);
    let mut reg = registration();
    let mut waits = Vec::new();
    for _ in 0..6 {
        reg.on_disconnect(&clock);
        waits.push(seconds_until_connect(&mut reg, &clock));
        reg.start(&clock);
    }
    assert_eq!(waits, [1.0, 2.0, 5.0, 10.0, 30.0, 30.0]);
}

#[test]
fn a_registration_that_held_for_a_minute_resets_the_reconnect_ladder() {
    let clock = FakeClock::new(0.0, UNIX_NOW);
    let mut reg = registration();
    reg.on_disconnect(&clock);
    seconds_until_connect(&mut reg, &clock);
    reg.start(&clock);
    reg.on_disconnect(&clock);
    assert_eq!(seconds_until_connect(&mut reg, &clock), 2.0);
    reg.start(&clock);
    reg.on_message(RelayServerMessage::Registered { session_ttl_seconds: 300 }, &clock);
    clock.advance(60.0);
    reg.on_disconnect(&clock);
    assert_eq!(seconds_until_connect(&mut reg, &clock), 1.0);
}

#[test]
fn a_session_ready_message_yields_a_dial_whose_first_bytes_are_the_relay_token() {
    let clock = FakeClock::new(0.0, UNIX_NOW);
    let mut reg = registration();
    registered(&mut reg, &clock);
    let session = relay_session();

    let actions = reg.on_message(
        RelayServerMessage::SessionReady {
            control_host: session.control_host.clone(),
            control_port: session.control_port,
            video_host: session.video_host.clone(),
            video_port: session.video_port,
            control_token: session.control_token,
            video_token: session.video_token,
            remaining_seconds: None,
        },
        &clock,
    );
    let [RegAction::DialSession(dialled)] = actions.as_slice() else {
        panic!("expected a dial, got {actions:?}");
    };
    assert_eq!(dialled, &session);

    let plan = dial::plan(dialled).expect("the relay's session is dialable");
    assert_eq!(plan.host, "relay.example");
    assert_eq!(plan.port, 4433);
    assert_eq!(dial::first_bytes(&plan), relay_token().0.to_vec());

    let (host_end, mut relay_end) = LoopbackStream::pair();
    RelayControlStream::open(&plan, host_end).expect("the token is written");
    assert_eq!(relay_end.receive().expect("open"), Some(relay_token().0.to_vec()));
}

#[test]
fn a_session_on_port_zero_is_not_dialled() {
    let mut session = relay_session();
    session.control_port = 0;
    assert_eq!(dial::plan(&session), Err(DialError::PortZero));
}

#[test]
fn a_session_ready_before_registration_is_ignored() {
    let clock = FakeClock::new(0.0, UNIX_NOW);
    let mut reg = registration();
    let session = relay_session();
    let actions = reg.on_message(
        RelayServerMessage::SessionReady {
            control_host: session.control_host,
            control_port: session.control_port,
            video_host: session.video_host,
            video_port: session.video_port,
            control_token: session.control_token,
            video_token: session.video_token,
            remaining_seconds: None,
        },
        &clock,
    );
    assert!(actions.is_empty());
}

#[test]
fn notifications_queued_before_registration_are_sent_in_order_once_registered() {
    let clock = FakeClock::new(0.0, UNIX_NOW);
    let mut reg = registration();
    assert!(reg.notify_device(notification("first")).is_empty());
    assert!(reg.notify_device(notification("second")).is_empty());

    open_link(&mut reg, &clock);
    let flushed = reg.on_message(RelayServerMessage::Registered { session_ttl_seconds: 300 }, &clock);

    let titles: Vec<String> = flushed
        .iter()
        .map(|action| match action {
            RegAction::Send(RelayClientMessage::NotifyDevice { title, .. }) => title.clone(),
            other => panic!("expected a notification, got {other:?}"),
        })
        .collect();
    assert_eq!(titles, ["first", "second"]);
}

#[test]
fn only_the_newest_sixteen_queued_notifications_are_kept() {
    let clock = FakeClock::new(0.0, UNIX_NOW);
    let mut reg = registration();
    for index in 0..17 {
        reg.notify_device(notification(&format!("n{index}")));
    }
    open_link(&mut reg, &clock);
    let flushed = reg.on_message(RelayServerMessage::Registered { session_ttl_seconds: 300 }, &clock);

    assert_eq!(flushed.len(), 16);
    assert!(matches!(&flushed[0], RegAction::Send(RelayClientMessage::NotifyDevice { title, .. }) if title == "n1"));
}

#[test]
fn a_registered_host_sends_a_notification_at_once() {
    let clock = FakeClock::new(0.0, UNIX_NOW);
    let mut reg = registration();
    registered(&mut reg, &clock);
    let sent = reg.notify_device(notification("now"));
    assert!(matches!(sent.as_slice(), [RegAction::Send(RelayClientMessage::NotifyDevice { .. })]));
}

#[test]
fn a_relay_error_drops_the_link_and_asks_the_caller_to_close_it() {
    let clock = FakeClock::new(0.0, UNIX_NOW);
    let mut reg = registration();
    registered(&mut reg, &clock);
    let actions = reg.on_message(
        RelayServerMessage::Error { code: "badProof".to_owned(), message: "refused".to_owned() },
        &clock,
    );
    assert_eq!(actions, vec![RegAction::Close]);
    assert!(!reg.is_registered());
    assert_eq!(seconds_until_connect(&mut reg, &clock), 2.0, "a link that was up for seconds keeps climbing the ladder");
}

#[test]
fn a_token_of_any_other_length_is_refused_before_dialling() {
    assert_eq!(dial::plan_with_token("relay.example", 4433, &[0; 15]), Err(DialError::TokenLength(15)));
    assert!(dial::plan_with_token("relay.example", 4433, &[0; TOKEN_SIZE]).is_ok());
}
