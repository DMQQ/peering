use super::*;
use crate::fakes::stream::LoopbackStream;
use peering_wire::relay_messages::Token;

fn session(control_port: u16) -> RelaySession {
    RelaySession {
        control_host: "relay.example".to_owned(),
        control_port,
        video_host: "relay.example".to_owned(),
        video_port: 7001,
        control_token: Token([0xC3; 16]),
        video_token: Token([0x5A; 16]),
    }
}

#[test]
fn a_session_plans_a_dial_to_its_control_port_with_the_control_role() {
    let plan = plan(&session(7000)).unwrap();
    assert_eq!(plan.host, "relay.example");
    assert_eq!(plan.port, 7000);
    assert_eq!(plan.token, [0xC3; 16]);
    assert_eq!(plan.then_role, ConnectionRole::Control);
}

#[test]
fn the_first_bytes_are_exactly_the_sixteen_byte_token() {
    let plan = plan(&session(7000)).unwrap();
    assert_eq!(first_bytes(&plan), vec![0xC3; 16]);
    assert_eq!(first_bytes(&plan).len(), TOKEN_LENGTH);
}

#[test]
fn a_token_of_the_wrong_length_is_rejected() {
    for length in [0, 15, 17, 32] {
        let token = vec![1u8; length];
        assert_eq!(plan_with_token("relay.example", 7000, &token), Err(DialError::TokenLength(length)));
    }
}

#[test]
fn a_port_of_zero_is_rejected() {
    assert_eq!(plan(&session(0)), Err(DialError::PortZero));
}

#[test]
fn an_empty_host_is_rejected() {
    assert_eq!(plan_with_token("", 7000, &[1; 16]), Err(DialError::EmptyHost));
}

#[test]
fn the_token_is_the_first_thing_the_relay_receives_on_the_connection() {
    let plan = plan(&session(7000)).unwrap();
    let (host_end, relay_end) = LoopbackStream::pair();
    let mut stream = RelayControlStream::open(&plan, host_end).unwrap();
    stream.send(b"after-token").unwrap();

    let mut relay_end = relay_end;
    assert_eq!(relay_end.receive().unwrap(), Some(vec![0xC3; 16]));
    assert_eq!(relay_end.receive().unwrap(), Some(b"after-token".to_vec()));
    assert_eq!(relay_end.receive().unwrap(), None);
}

#[test]
fn the_wrapper_passes_receives_and_the_peer_key_through() {
    let plan = plan(&session(7000)).unwrap();
    let (host_end, mut relay_end) = LoopbackStream::pair();
    let mut stream = RelayControlStream::open(&plan, host_end.with_peer_public_key(vec![4, 9])).unwrap();
    relay_end.send(b"from-relay").unwrap();
    assert_eq!(stream.receive().unwrap().unwrap(), b"from-relay".to_vec());
    assert_eq!(stream.peer_public_key(), Some(vec![4, 9]));
}

#[test]
fn a_closed_connection_fails_the_token_write() {
    let plan = plan(&session(7000)).unwrap();
    let (mut host_end, _relay_end) = LoopbackStream::pair();
    host_end.close();
    assert!(RelayControlStream::open(&plan, host_end).is_err());
}
