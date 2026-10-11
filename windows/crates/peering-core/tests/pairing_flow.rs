//! A scripted phone pairs with the host session: the code match, the QR proof, the Mac's approval, and the pin.

mod common;

use std::sync::Arc;

use common::*;
use peering_core::session::actions::{CloseReason, HostEvent, SessionAction};
use peering_core::session::deps::PinStore;
use peering_core::session::handshake::PROTOCOL_VERSION;
use peering_core::session::state::HandshakeState;
use peering_wire::framing::MessageKind;
use peering_wire::handshake::ServerHello;

fn fresh_host(pins: Arc<MemoryPins>) -> peering_core::session::handshake::HostSession {
    host_session(pins, Some(CLIENT_KEY.to_vec()), clock_at(0.0))
}

fn server_hello_of(actions: &[SessionAction]) -> ServerHello {
    decode_json(&sent_of(actions, MessageKind::ServerHello).expect("a serverHello frame"))
}

#[test]
fn qr_proof_pairs_the_phone_once_both_ends_show_the_same_code() {
    let pins = Arc::new(MemoryPins::default());
    let mut host = fresh_host(pins.clone());
    let mut phone = PairingClient::new();
    let (code, secret) = pair_up_to_code(&mut host, &mut phone);
    assert_eq!(code.len(), 6);

    let actions = host.on_frame(phone.confirm(true, Some(phone.proof(&secret))));

    assert!(pair_result_of(&actions).accepted);
    assert!(actions.contains(&SessionAction::Emit(HostEvent::PairingCompleted {
        client_name: CLIENT_NAME.to_owned(),
        accepted: true,
    })));
    assert!(has_authorised(&actions));
    assert_eq!(host.state(), HandshakeState::Ready);
    assert_eq!(pins.pin_for(CLIENT_ID), Some(CLIENT_KEY.to_vec()));
}

#[test]
fn the_server_hello_of_an_unpaired_phone_leaves_out_the_mac_addresses() {
    let mut host = fresh_host(Arc::new(MemoryPins::default()));
    host.on_frame(role_frame(CONTROL_ROLE));
    let actions = host.on_frame(PairingClient::new().hello());

    let server = server_hello_of(&actions);
    assert!(!server.already_paired);
    assert_eq!(server.mac_addresses, None);
    assert_eq!(server.protocol_version, PROTOCOL_VERSION);
    assert_eq!(server.host_platform.as_deref(), Some("windows"));
}

#[test]
fn a_wrong_qr_proof_is_refused_and_nothing_is_pinned() {
    let pins = Arc::new(MemoryPins::default());
    let mut host = fresh_host(pins.clone());
    let mut phone = PairingClient::new();
    pair_up_to_code(&mut host, &mut phone);

    let other_secret = [0x00; 16];
    let actions = host.on_frame(phone.confirm(true, Some(phone.proof(&other_secret))));

    let result = pair_result_of(&actions);
    assert!(!result.accepted);
    assert_eq!(result.reason.as_deref(), Some("The pairing code was not accepted."));
    assert_eq!(close_reason(&actions), Some(CloseReason::PairingRejected));
    assert!(!has_authorised(&actions));
    assert_eq!(pins.pin_for(CLIENT_ID), None);
    assert_eq!(host.state(), HandshakeState::Failed);
}

#[test]
fn typed_digits_ask_the_mac_user_and_pair_only_when_approved() {
    let pins = Arc::new(MemoryPins::default());
    let mut host = fresh_host(pins.clone());
    let mut phone = PairingClient::new();
    pair_up_to_code(&mut host, &mut phone);

    let asked = host.on_frame(phone.confirm(true, None));
    assert!(asked.contains(&SessionAction::RequestApproval { client_name: CLIENT_NAME.to_owned() }));
    assert_eq!(host.state(), HandshakeState::AwaitingApproval);
    assert_eq!(pins.pin_for(CLIENT_ID), None, "nothing is pinned while the Mac user decides");

    let approved = host.resolve_approval(true);
    assert!(pair_result_of(&approved).accepted);
    assert!(has_authorised(&approved));
    assert_eq!(host.state(), HandshakeState::Ready);
    assert_eq!(pins.pin_for(CLIENT_ID), Some(CLIENT_KEY.to_vec()));
}

#[test]
fn a_declined_approval_refuses_the_phone_and_pins_nothing() {
    let pins = Arc::new(MemoryPins::default());
    let mut host = fresh_host(pins.clone());
    let mut phone = PairingClient::new();
    pair_up_to_code(&mut host, &mut phone);
    host.on_frame(phone.confirm(true, None));

    let declined = host.resolve_approval(false);

    let result = pair_result_of(&declined);
    assert!(!result.accepted);
    assert_eq!(result.reason.as_deref(), Some("The pairing was declined on the Mac."));
    assert_eq!(close_reason(&declined), Some(CloseReason::PairingRejected));
    assert!(declined.contains(&SessionAction::Emit(HostEvent::PairingCompleted {
        client_name: CLIENT_NAME.to_owned(),
        accepted: false,
    })));
    assert_eq!(pins.pin_for(CLIENT_ID), None);
    assert_eq!(host.state(), HandshakeState::Failed);
}

#[test]
fn an_approval_answer_with_no_pending_request_is_ignored() {
    let mut host = fresh_host(Arc::new(MemoryPins::default()));
    host.on_frame(role_frame(CONTROL_ROLE));
    assert!(host.resolve_approval(true).is_empty());
    assert_eq!(host.state(), HandshakeState::AwaitingHello);
}

#[test]
fn a_phone_that_rejects_the_code_is_refused() {
    let pins = Arc::new(MemoryPins::default());
    let mut host = fresh_host(pins.clone());
    let mut phone = PairingClient::new();
    pair_up_to_code(&mut host, &mut phone);

    let actions = host.on_frame(phone.confirm(false, None));

    let result = pair_result_of(&actions);
    assert!(!result.accepted);
    assert_eq!(result.reason.as_deref(), Some("The codes did not match."));
    assert_eq!(close_reason(&actions), Some(CloseReason::PairingRejected));
    assert_eq!(pins.pin_for(CLIENT_ID), None);
}

#[test]
fn a_pin_that_cannot_be_saved_reports_not_paired() {
    let pins = Arc::new(MemoryPins::default());
    pins.set_fail_writes(true);
    let mut host = fresh_host(pins.clone());
    let mut phone = PairingClient::new();
    let (_, secret) = pair_up_to_code(&mut host, &mut phone);

    let actions = host.on_frame(phone.confirm(true, Some(phone.proof(&secret))));

    let result = pair_result_of(&actions);
    assert!(!result.accepted, "the phone must not be told it is paired when the pin was not written");
    assert_eq!(result.reason.as_deref(), Some("Could not save the pairing."));
    assert_eq!(close_reason(&actions), Some(CloseReason::PairingNotSaved));
    assert!(!has_authorised(&actions));
    assert_eq!(pins.pin_for(CLIENT_ID), None);
}

#[test]
fn a_known_phone_reconnects_without_pairing_again() {
    let pins = Arc::new(MemoryPins::with_device(paired_device(&CLIENT_KEY)));
    let mut host = fresh_host(pins);
    host.on_frame(role_frame(CONTROL_ROLE));
    let actions = host.on_frame(PairingClient::new().hello());

    let server = server_hello_of(&actions);
    assert!(server.already_paired);
    assert_eq!(server.mac_addresses, Some(vec![MAC_ADDRESS.to_owned()]));
    assert!(has_authorised(&actions));
    assert_eq!(host.state(), HandshakeState::Ready);
    assert_eq!(sent_of(&actions, MessageKind::PairCommit), None);
}

#[test]
fn a_phone_that_lost_its_pin_is_paired_again_even_though_the_host_knows_it() {
    let pins = Arc::new(MemoryPins::with_device(paired_device(&CLIENT_KEY)));
    let mut host = fresh_host(pins);
    host.on_frame(role_frame(CONTROL_ROLE));
    let actions = host.on_frame(PairingClient::new().hello_with(|mut hello| {
        hello.lost_pairing = Some(true);
        hello
    }));

    assert!(!server_hello_of(&actions).already_paired);
    assert!(sent_of(&actions, MessageKind::PairCommit).is_some());
    assert!(!has_authorised(&actions));
}

#[test]
fn a_phone_presenting_a_key_other_than_its_pin_is_refused() {
    let pins = Arc::new(MemoryPins::with_device(paired_device(&[0x01; 65])));
    let mut host = fresh_host(pins);
    host.on_frame(role_frame(CONTROL_ROLE));
    let actions = host.on_frame(PairingClient::new().hello());

    assert_eq!(
        close_reason(&actions),
        Some(CloseReason::ClientKeyMismatch { client_id: CLIENT_ID.to_owned() })
    );
    assert!(!has_authorised(&actions));
}
