use std::sync::Arc;

use peering_wire::framing::{Frame, MessageKind};
use peering_wire::handshake::{PairConfirm, PairingCommit, PairingReveal, ServerHello};
use peering_wire::sas::{self, PairingTranscript};
use serde::Serialize;

use super::*;
use crate::session::actions::{CloseReason, HostEvent, SessionAction};
use crate::session::deps::PairedDevice;
use crate::session::state::HandshakeState;
use crate::session::test_support::*;

fn json_frame<T: Serialize>(kind: MessageKind, value: &T) -> Frame {
    Frame::new(kind, serde_json::to_vec(value).expect("test message serialises"))
}

fn client_transcript() -> PairingTranscript {
    PairingTranscript {
        protocol_version: PROTOCOL_VERSION,
        client_id: CLIENT_ID.into(),
        server_id: HOST_ID.into(),
        client_ephemeral_public_key: CLIENT_EPHEMERAL.to_vec(),
        server_ephemeral_public_key: HOST_EPHEMERAL.to_vec(),
        client_nonce: CLIENT_NONCE.to_vec(),
        server_nonce: HOST_NONCE.to_vec(),
        server_identity_public_key: HOST_KEY.to_vec(),
    }
}

fn commit_frame() -> Frame {
    let commitment = sas::commitment(&CLIENT_EPHEMERAL, &CLIENT_NONCE).to_vec();
    json_frame(MessageKind::PairCommit, &PairingCommit { commitment })
}

fn reveal_frame() -> Frame {
    json_frame(
        MessageKind::PairReveal,
        &PairingReveal { ephemeral_public_key: CLIENT_EPHEMERAL.to_vec(), nonce: CLIENT_NONCE.to_vec() },
    )
}

fn confirm_frame(accepted: bool, proof: Option<Vec<u8>>) -> Frame {
    json_frame(MessageKind::PairConfirm, &PairConfirm { accepted, proof })
}

fn paired_pins() -> Arc<MemoryPins> {
    Arc::new(MemoryPins::with_device(PairedDevice {
        id: CLIENT_ID.to_owned(),
        name: CLIENT_NAME.to_owned(),
        public_key: CLIENT_KEY.to_vec(),
        last_seen_unix: 1,
    }))
}

fn unpaired() -> HostSession {
    session_with(Arc::new(MemoryPins::default()), Some(CLIENT_KEY.to_vec()))
}

/// Role then hello, returning the hello's actions.
fn open_with_hello(session: &mut HostSession, hello: Frame) -> Vec<SessionAction> {
    session.on_frame(role_frame(1));
    session.on_frame(hello)
}

/// Client commit then reveal: returns the actions of the reveal, which carry the pairing code.
fn reach_code(session: &mut HostSession) -> Vec<SessionAction> {
    session.on_frame(commit_frame());
    session.on_frame(reveal_frame())
}

fn pairing_code_of(actions: &[SessionAction]) -> String {
    actions
        .iter()
        .find_map(|action| match action {
            SessionAction::Emit(HostEvent::PairingCode { code, .. }) => Some(code.clone()),
            _ => None,
        })
        .expect("a pairing code event")
}

fn pair_result_of(actions: &[SessionAction]) -> peering_wire::handshake::PairResult {
    let frame = sent_frames(actions)
        .into_iter()
        .find(|frame| frame.kind == MessageKind::PairResult)
        .expect("a pairResult frame");
    serde_json::from_slice(&frame.payload).expect("pairResult decodes")
}

fn server_hello_of(actions: &[SessionAction]) -> ServerHello {
    let frame = sent_frames(actions)
        .into_iter()
        .find(|frame| frame.kind == MessageKind::ServerHello)
        .expect("a serverHello frame");
    serde_json::from_slice(&frame.payload).expect("serverHello decodes")
}

#[test]
fn already_paired_client_is_authorised_without_pairing() {
    let mut session = session_with(paired_pins(), Some(CLIENT_KEY.to_vec()));
    let hello = client_hello_json(PROTOCOL_VERSION, CLIENT_ID, "");
    let actions = open_with_hello(&mut session, hello);

    let server = server_hello_of(&actions);
    assert!(server.already_paired);
    assert_eq!(server.mac_addresses, Some(vec!["aa:bb:cc:dd:ee:ff".to_owned()]));
    assert_eq!(server.capabilities.supports_video_pause, Some(true));
    assert!(actions.contains(&SessionAction::Authorized));
    assert_eq!(session.state(), HandshakeState::Ready);
    assert!(!sent_frames(&actions).iter().any(|frame| frame.kind == MessageKind::PairCommit));
}

#[test]
fn resume_source_is_forwarded_only_to_a_paired_client() {
    let mut session = session_with(paired_pins(), Some(CLIENT_KEY.to_vec()));
    let hello = client_hello_json(PROTOCOL_VERSION, CLIENT_ID, r#","resumeSource":{"display":{"_0":7}}"#);
    let actions = open_with_hello(&mut session, hello);
    assert!(actions.contains(&SessionAction::ForwardCommand(RemoteCommand::SetCaptureSource {
        source: CaptureSource::Display { id: 7 },
    })));
}

#[test]
fn resume_source_is_ignored_before_pairing() {
    let mut session = unpaired();
    let hello = client_hello_json(PROTOCOL_VERSION, CLIENT_ID, r#","resumeSource":{"display":{"_0":7}}"#);
    let actions = open_with_hello(&mut session, hello);
    assert!(!actions.iter().any(|action| matches!(action, SessionAction::ForwardCommand(_))));
}

#[test]
fn unpaired_hello_offers_no_mac_addresses_and_starts_with_a_commitment() {
    let mut session = unpaired();
    let actions = open_with_hello(&mut session, client_hello_json(PROTOCOL_VERSION, CLIENT_ID, ""));

    let server = server_hello_of(&actions);
    assert!(!server.already_paired);
    assert_eq!(server.mac_addresses, None);
    let commit: PairingCommit = {
        let frame = sent_frames(&actions)
            .into_iter()
            .find(|frame| frame.kind == MessageKind::PairCommit)
            .expect("the host commits first");
        serde_json::from_slice(&frame.payload).expect("commit decodes")
    };
    assert_eq!(commit.commitment, sas::commitment(&HOST_EPHEMERAL, &HOST_NONCE).to_vec());
    assert_eq!(session.state(), HandshakeState::AwaitingClientCommit);
}

#[test]
fn client_reveal_after_commit_emits_the_code_and_secret() {
    let mut session = unpaired();
    open_with_hello(&mut session, client_hello_json(PROTOCOL_VERSION, CLIENT_ID, ""));
    let commit_actions = session.on_frame(commit_frame());
    assert!(sent_frames(&commit_actions).iter().any(|frame| frame.kind == MessageKind::PairReveal));
    assert_eq!(session.state(), HandshakeState::AwaitingClientReveal);

    let actions = session.on_frame(reveal_frame());
    assert_eq!(pairing_code_of(&actions), client_transcript().code());
    assert!(actions.contains(&SessionAction::Emit(HostEvent::PairingCode {
        code: client_transcript().code(),
        secret: SECRET.to_vec(),
        client_name: CLIENT_NAME.to_owned(),
        via_relay: false,
    })));
    assert_eq!(session.state(), HandshakeState::AwaitingConfirmation);
}

#[test]
fn valid_qr_proof_pairs_and_records_the_pin() {
    let pins = Arc::new(MemoryPins::default());
    let mut session = session_with(pins.clone(), Some(CLIENT_KEY.to_vec()));
    open_with_hello(&mut session, client_hello_json(PROTOCOL_VERSION, CLIENT_ID, ""));
    reach_code(&mut session);

    let actions = session.on_frame(confirm_frame(true, Some(client_transcript().proof(&SECRET))));
    assert!(pair_result_of(&actions).accepted);
    assert!(actions.contains(&SessionAction::Emit(HostEvent::PairingCompleted {
        client_name: CLIENT_NAME.to_owned(),
        accepted: true,
    })));
    assert!(actions.contains(&SessionAction::Authorized));
    assert_eq!(session.state(), HandshakeState::Ready);
    assert_eq!(pins.pin_for(CLIENT_ID), Some(CLIENT_KEY.to_vec()));
}

#[test]
fn typed_digits_wait_for_approval_then_pair_when_approved() {
    let pins = Arc::new(MemoryPins::default());
    let mut session = session_with(pins.clone(), Some(CLIENT_KEY.to_vec()));
    open_with_hello(&mut session, client_hello_json(PROTOCOL_VERSION, CLIENT_ID, ""));
    reach_code(&mut session);

    let actions = session.on_frame(confirm_frame(true, None));
    assert!(actions.contains(&SessionAction::RequestApproval { client_name: CLIENT_NAME.to_owned() }));
    assert_eq!(session.state(), HandshakeState::AwaitingApproval);
    assert_eq!(pins.pin_for(CLIENT_ID), None);

    let approved = session.resolve_approval(true);
    assert!(pair_result_of(&approved).accepted);
    assert!(approved.contains(&SessionAction::Authorized));
    assert_eq!(pins.pin_for(CLIENT_ID), Some(CLIENT_KEY.to_vec()));
}

#[test]
fn frames_during_approval_are_ignored() {
    let mut session = unpaired();
    open_with_hello(&mut session, client_hello_json(PROTOCOL_VERSION, CLIENT_ID, ""));
    reach_code(&mut session);
    session.on_frame(confirm_frame(true, None));
    assert!(session.on_frame(Frame::empty(MessageKind::Ping)).is_empty());
    assert_eq!(session.state(), HandshakeState::AwaitingApproval);
}

#[test]
fn declined_approval_refuses_and_stores_nothing() {
    let pins = Arc::new(MemoryPins::default());
    let mut session = session_with(pins.clone(), Some(CLIENT_KEY.to_vec()));
    open_with_hello(&mut session, client_hello_json(PROTOCOL_VERSION, CLIENT_ID, ""));
    reach_code(&mut session);
    session.on_frame(confirm_frame(true, None));

    let actions = session.resolve_approval(false);
    let result = pair_result_of(&actions);
    assert!(!result.accepted);
    assert_eq!(result.reason.as_deref(), Some("The pairing was declined on the Mac."));
    assert_eq!(find_close(&actions), Some(&CloseReason::PairingRejected));
    assert_eq!(session.state(), HandshakeState::Failed);
    assert_eq!(pins.pin_for(CLIENT_ID), None);
}

#[test]
fn approval_answer_without_a_pending_approval_does_nothing() {
    let mut session = unpaired();
    open_with_hello(&mut session, client_hello_json(PROTOCOL_VERSION, CLIENT_ID, ""));
    assert!(session.resolve_approval(true).is_empty());
    assert_eq!(session.state(), HandshakeState::AwaitingClientCommit);
}

#[test]
fn proof_made_with_another_secret_is_rejected() {
    let pins = Arc::new(MemoryPins::default());
    let mut session = session_with(pins.clone(), Some(CLIENT_KEY.to_vec()));
    open_with_hello(&mut session, client_hello_json(PROTOCOL_VERSION, CLIENT_ID, ""));
    reach_code(&mut session);

    let actions = session.on_frame(confirm_frame(true, Some(client_transcript().proof(b"another secret!!"))));
    let result = pair_result_of(&actions);
    assert!(!result.accepted);
    assert_eq!(result.reason.as_deref(), Some("The pairing code was not accepted."));
    assert_eq!(find_close(&actions), Some(&CloseReason::PairingRejected));
    assert_eq!(pins.pin_for(CLIENT_ID), None);
}

#[test]
fn client_refusing_the_codes_closes_the_pairing() {
    let mut session = unpaired();
    open_with_hello(&mut session, client_hello_json(PROTOCOL_VERSION, CLIENT_ID, ""));
    reach_code(&mut session);

    let actions = session.on_frame(confirm_frame(false, None));
    assert_eq!(pair_result_of(&actions).reason.as_deref(), Some("The codes did not match."));
    assert_eq!(find_close(&actions), Some(&CloseReason::PairingRejected));
}

#[test]
fn failed_pin_write_reports_failure_and_closes() {
    let pins = Arc::new(MemoryPins::default());
    pins.set_fail_writes(true);
    let mut session = session_with(pins.clone(), Some(CLIENT_KEY.to_vec()));
    open_with_hello(&mut session, client_hello_json(PROTOCOL_VERSION, CLIENT_ID, ""));
    reach_code(&mut session);

    let actions = session.on_frame(confirm_frame(true, Some(client_transcript().proof(&SECRET))));
    let result = pair_result_of(&actions);
    assert!(!result.accepted);
    assert_eq!(result.reason.as_deref(), Some("Could not save the pairing."));
    assert_eq!(find_close(&actions), Some(&CloseReason::PairingNotSaved));
    assert_eq!(pins.pin_for(CLIENT_ID), None);
}

#[test]
fn version_mismatch_closes_before_any_reply() {
    let mut session = unpaired();
    let actions = open_with_hello(&mut session, client_hello_json(19, CLIENT_ID, ""));
    assert_eq!(find_close(&actions), Some(&CloseReason::ProtocolMismatch { client: 19, host: PROTOCOL_VERSION }));
    assert!(sent_frames(&actions).is_empty());
    assert_eq!(session.state(), HandshakeState::Failed);
}

#[test]
fn pinned_id_with_another_key_closes_without_announcing_the_client() {
    let pins = Arc::new(MemoryPins::with_device(PairedDevice {
        id: CLIENT_ID.to_owned(),
        name: CLIENT_NAME.to_owned(),
        public_key: vec![0x01; 65],
        last_seen_unix: 1,
    }));
    let mut session = session_with(pins, Some(CLIENT_KEY.to_vec()));
    let actions = open_with_hello(&mut session, client_hello_json(PROTOCOL_VERSION, CLIENT_ID, ""));
    assert_eq!(find_close(&actions), Some(&CloseReason::ClientKeyMismatch { client_id: CLIENT_ID.to_owned() }));
    assert!(!actions.iter().any(|action| matches!(action, SessionAction::Emit(_))));
}

#[test]
fn client_id_of_256_bytes_is_accepted_and_257_is_refused() {
    let longest = "a".repeat(256);
    let mut accepted = unpaired();
    let actions = open_with_hello(&mut accepted, client_hello_json(PROTOCOL_VERSION, &longest, ""));
    assert_eq!(find_close(&actions), None);

    let too_long = "a".repeat(257);
    let mut refused = unpaired();
    let actions = open_with_hello(&mut refused, client_hello_json(PROTOCOL_VERSION, &too_long, ""));
    assert_eq!(find_close(&actions), Some(&CloseReason::MalformedHello));
}

#[test]
fn client_name_of_257_bytes_is_refused() {
    let json = format!(
        r#"{{"clientID":"{CLIENT_ID}","clientName":"{}","protocolVersion":20,"wantsPairing":true}}"#,
        "n".repeat(257)
    );
    let mut session = unpaired();
    let actions = open_with_hello(&mut session, Frame::new(MessageKind::ClientHello, json.into_bytes()));
    assert_eq!(find_close(&actions), Some(&CloseReason::MalformedHello));
}

#[test]
fn lost_pairing_repeats_the_pairing_for_a_pinned_client() {
    let mut session = session_with(paired_pins(), Some(CLIENT_KEY.to_vec()));
    let hello = client_hello_json(PROTOCOL_VERSION, CLIENT_ID, r#","lostPairing":true"#);
    let actions = open_with_hello(&mut session, hello);
    assert!(!server_hello_of(&actions).already_paired);
    assert_eq!(session.state(), HandshakeState::AwaitingClientCommit);
}

#[test]
fn missing_peer_key_closes_the_session() {
    let mut session = session_with(Arc::new(MemoryPins::default()), None);
    let actions = open_with_hello(&mut session, client_hello_json(PROTOCOL_VERSION, CLIENT_ID, ""));
    assert_eq!(find_close(&actions), Some(&CloseReason::NoPeerKey));
    assert!(!actions.iter().any(|action| matches!(action, SessionAction::Emit(_))));
}

#[test]
fn video_role_is_handed_over_and_parked() {
    let mut session = unpaired();
    let actions = session.on_frame(role_frame(2));
    assert_eq!(actions, vec![SessionAction::VideoConnection]);
    assert_eq!(session.state(), HandshakeState::Failed);
    assert!(session.on_frame(client_hello_json(PROTOCOL_VERSION, CLIENT_ID, "")).is_empty());
}

#[test]
fn an_unknown_role_closes_the_session() {
    let mut session = unpaired();
    let actions = session.on_frame(role_frame(9));
    assert_eq!(find_close(&actions), Some(&CloseReason::UnexpectedFrame(MessageKind::ConnectionRole)));
}

#[test]
fn first_frame_that_is_not_a_role_closes_the_session() {
    let mut session = unpaired();
    let actions = session.on_frame(Frame::empty(MessageKind::Ping));
    assert_eq!(find_close(&actions), Some(&CloseReason::UnexpectedFrame(MessageKind::Ping)));
}

#[test]
fn a_ping_before_hello_closes_the_session() {
    let mut session = unpaired();
    session.on_frame(role_frame(1));
    let actions = session.on_frame(Frame::empty(MessageKind::Ping));
    assert_eq!(find_close(&actions), Some(&CloseReason::UnexpectedFrame(MessageKind::Ping)));
}

#[test]
fn malformed_hello_json_closes_the_session() {
    let mut session = unpaired();
    let actions = open_with_hello(&mut session, Frame::new(MessageKind::ClientHello, b"{not json".to_vec()));
    assert_eq!(find_close(&actions), Some(&CloseReason::MalformedPayload(MessageKind::ClientHello)));
}

#[test]
fn hello_over_the_control_payload_limit_is_refused_before_parsing() {
    let mut session = unpaired();
    let oversized = Frame::new(MessageKind::ClientHello, vec![b' '; MAX_CONTROL_PAYLOAD + 1]);
    let actions = open_with_hello(&mut session, oversized);
    assert_eq!(find_close(&actions), Some(&CloseReason::MalformedPayload(MessageKind::ClientHello)));
}

#[test]
fn commitment_that_does_not_match_the_reveal_closes_the_session() {
    let mut session = unpaired();
    open_with_hello(&mut session, client_hello_json(PROTOCOL_VERSION, CLIENT_ID, ""));
    session.on_frame(commit_frame());
    let forged = json_frame(
        MessageKind::PairReveal,
        &PairingReveal { ephemeral_public_key: CLIENT_EPHEMERAL.to_vec(), nonce: b"a different nonce".to_vec() },
    );
    let actions = session.on_frame(forged);
    assert_eq!(find_close(&actions), Some(&CloseReason::CommitmentMismatch));
    assert!(!actions.iter().any(|action| matches!(action, SessionAction::Emit(_))));
}

#[test]
fn ready_session_hands_frames_to_the_dispatcher() {
    let mut session = session_with(paired_pins(), Some(CLIENT_KEY.to_vec()));
    open_with_hello(&mut session, client_hello_json(PROTOCOL_VERSION, CLIENT_ID, ""));
    let ping = Frame::new(MessageKind::Ping, b"{\"sequence\":3}".to_vec());
    assert_eq!(session.on_frame(ping.clone()), vec![SessionAction::ForwardFrame(ping)]);
}

#[test]
fn reveal_before_the_client_commit_closes_the_session() {
    let mut session = unpaired();
    open_with_hello(&mut session, client_hello_json(PROTOCOL_VERSION, CLIENT_ID, ""));
    let actions = session.on_frame(reveal_frame());
    assert_eq!(find_close(&actions), Some(&CloseReason::UnexpectedFrame(MessageKind::PairReveal)));
}

#[test]
fn pin_store_received_the_client_name_and_clock_time() {
    let pins = Arc::new(MemoryPins::default());
    let mut session = session_with(pins.clone(), Some(CLIENT_KEY.to_vec()));
    open_with_hello(&mut session, client_hello_json(PROTOCOL_VERSION, CLIENT_ID, ""));
    reach_code(&mut session);
    session.on_frame(confirm_frame(true, Some(client_transcript().proof(&SECRET))));
    let device = pins.devices().into_iter().next().expect("one paired device");
    assert_eq!(device.name, CLIENT_NAME);
    assert_eq!(device.last_seen_unix, UNIX_NOW);
}
