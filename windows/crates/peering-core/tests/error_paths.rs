//! What the host refuses and what it lets pass: bad versions and sizes, frames of the wrong kind for the state, unknown
//! commands, observe mode, and the framing limits. Each refusal ends the session or drops the frame, as documented.

mod common;

use common::*;
use peering_core::fakes::input::RecordingInput;
use peering_core::session::actions::{CloseReason, SessionAction};
use peering_core::session::deps::PinStore;
use peering_core::session::dispatch::{on_ready_frame, DispatchOutcome, IgnoreReason, ReadyOutcome};
use peering_core::session::handshake::PROTOCOL_VERSION;
use peering_core::session::state::HandshakeState;
use peering_wire::command::{MouseButton, Modifiers, RemoteCommand};
use peering_wire::framing::{Frame, FrameDecoder, FramingError, MessageKind, MAX_FRAME_LENGTH};
use peering_wire::handshake::PairingCommit;
use peering_wire::source::{CaptureSource, NormalizedPoint};

fn unpaired_host() -> peering_core::session::handshake::HostSession {
    host_session(std::sync::Arc::new(MemoryPins::default()), Some(CLIENT_KEY.to_vec()), clock_at(0.0))
}

fn paired_ready_host() -> peering_core::session::handshake::HostSession {
    let pins: std::sync::Arc<dyn PinStore> =
        std::sync::Arc::new(MemoryPins::with_device(paired_device(&CLIENT_KEY)));
    let mut host = host_session(pins, Some(CLIENT_KEY.to_vec()), clock_at(0.0));
    host.on_frame(role_frame(CONTROL_ROLE));
    host.on_frame(PairingClient::new().hello());
    host
}

fn command_frame(json: &str) -> Frame {
    Frame::new(MessageKind::Command, json.as_bytes().to_vec())
}

fn dispatch_one(frame: &Frame, observe_mode: bool) -> (ReadyOutcome, RecordingInput, RecordingSource) {
    let mut input = RecordingInput::default();
    let mut source = RecordingSource::default();
    let outcome = {
        let mut ctx = dispatch_context(&mut input, &mut source, observe_mode);
        on_ready_frame(frame, &mut ctx)
    };
    (outcome, input, source)
}

#[test]
fn a_hello_for_another_protocol_version_is_closed_before_any_reply() {
    let mut host = unpaired_host();
    host.on_frame(role_frame(CONTROL_ROLE));

    let actions = host.on_frame(client_hello_with_version(PROTOCOL_VERSION - 1));

    assert_eq!(
        close_reason(&actions),
        Some(CloseReason::ProtocolMismatch { client: PROTOCOL_VERSION - 1, host: PROTOCOL_VERSION })
    );
    assert!(sent_frames(&actions).is_empty(), "no serverHello is sent to a client on another version");
    assert_eq!(host.state(), HandshakeState::Failed);
}

fn client_hello_with_version(version: u16) -> Frame {
    PairingClient::new().hello_with(|mut hello| {
        hello.protocol_version = version;
        hello
    })
}

#[test]
fn an_identifier_of_exactly_the_limit_is_accepted_and_one_byte_more_is_refused() {
    let at_limit = "a".repeat(256);
    let mut host = unpaired_host();
    host.on_frame(role_frame(CONTROL_ROLE));
    let actions = host.on_frame(PairingClient::new().hello_with(|mut hello| {
        hello.client_id = at_limit.clone();
        hello
    }));
    assert!(close_reason(&actions).is_none());

    let mut host = unpaired_host();
    host.on_frame(role_frame(CONTROL_ROLE));
    let actions = host.on_frame(PairingClient::new().hello_with(|mut hello| {
        hello.client_id = "a".repeat(257);
        hello
    }));
    assert_eq!(close_reason(&actions), Some(CloseReason::MalformedHello));

    let mut host = unpaired_host();
    host.on_frame(role_frame(CONTROL_ROLE));
    let actions = host.on_frame(PairingClient::new().hello_with(|mut hello| {
        hello.client_name = "n".repeat(257);
        hello
    }));
    assert_eq!(close_reason(&actions), Some(CloseReason::MalformedHello));
}

#[test]
fn a_control_payload_over_sixty_four_kibibytes_is_refused_before_it_is_parsed() {
    let mut host = unpaired_host();
    host.on_frame(role_frame(CONTROL_ROLE));
    let oversized = Frame::new(MessageKind::ClientHello, vec![b' '; 64 * 1024 + 1]);

    let actions = host.on_frame(oversized);

    assert_eq!(close_reason(&actions), Some(CloseReason::MalformedPayload(MessageKind::ClientHello)));
}

#[test]
fn a_hello_that_is_not_json_closes_the_session() {
    let mut host = unpaired_host();
    host.on_frame(role_frame(CONTROL_ROLE));
    let actions = host.on_frame(Frame::new(MessageKind::ClientHello, b"{not json".to_vec()));
    assert_eq!(close_reason(&actions), Some(CloseReason::MalformedPayload(MessageKind::ClientHello)));
}

#[test]
fn a_connection_role_naming_no_role_is_refused() {
    let mut host = unpaired_host();
    let actions = host.on_frame(role_frame(9));
    assert_eq!(close_reason(&actions), Some(CloseReason::UnexpectedFrame(MessageKind::ConnectionRole)));
}

#[test]
fn a_frame_of_the_wrong_kind_closes_the_handshake_in_each_state_it_is_not_expected_in() {
    let mut awaiting_role = unpaired_host();
    assert_eq!(
        close_reason(&awaiting_role.on_frame(Frame::empty(MessageKind::Ping))),
        Some(CloseReason::UnexpectedFrame(MessageKind::Ping))
    );

    let mut awaiting_hello = unpaired_host();
    awaiting_hello.on_frame(role_frame(CONTROL_ROLE));
    let commit = encode_json(MessageKind::PairCommit, &PairingCommit { commitment: vec![0; 32] });
    assert_eq!(
        close_reason(&awaiting_hello.on_frame(commit)),
        Some(CloseReason::UnexpectedFrame(MessageKind::PairCommit))
    );

    let mut awaiting_commit = unpaired_host();
    let phone = PairingClient::new();
    awaiting_commit.on_frame(role_frame(CONTROL_ROLE));
    awaiting_commit.on_frame(phone.hello());
    assert_eq!(
        close_reason(&awaiting_commit.on_frame(phone.reveal())),
        Some(CloseReason::UnexpectedFrame(MessageKind::PairReveal))
    );

    let mut awaiting_reveal = unpaired_host();
    let mut phone = PairingClient::new();
    awaiting_reveal.on_frame(role_frame(CONTROL_ROLE));
    let hello_actions = awaiting_reveal.on_frame(phone.hello());
    phone.take_host_commit(&sent_of(&hello_actions, MessageKind::PairCommit).expect("host commits"));
    awaiting_reveal.on_frame(phone.commit());
    assert_eq!(
        close_reason(&awaiting_reveal.on_frame(phone.confirm(true, None))),
        Some(CloseReason::UnexpectedFrame(MessageKind::PairConfirm))
    );
}

#[test]
fn a_confirmation_that_does_not_decode_closes_the_pairing() {
    let mut host = unpaired_host();
    let mut phone = PairingClient::new();
    pair_up_to_code(&mut host, &mut phone);

    let actions = host.on_frame(Frame::new(MessageKind::PairConfirm, b"{\"accepted\":\"yes\"}".to_vec()));

    assert_eq!(close_reason(&actions), Some(CloseReason::MalformedPayload(MessageKind::PairConfirm)));
}

#[test]
fn a_frame_while_the_mac_user_decides_is_ignored_without_closing() {
    let mut host = unpaired_host();
    let mut phone = PairingClient::new();
    pair_up_to_code(&mut host, &mut phone);
    host.on_frame(phone.confirm(true, None));
    assert_eq!(host.state(), HandshakeState::AwaitingApproval);

    let actions = host.on_frame(Frame::empty(MessageKind::Ping));

    assert!(actions.is_empty());
    assert_eq!(host.state(), HandshakeState::AwaitingApproval);
}

#[test]
fn an_unknown_command_case_ends_a_ready_session() {
    let (outcome, input, source) = dispatch_one(&command_frame(r#"{"teleport":{}}"#), false);

    assert_eq!(outcome, ReadyOutcome::Close(CloseReason::MalformedPayload(MessageKind::Command)));
    assert!(input.applied().is_empty());
    assert!(source.sources.is_empty());
}

#[test]
fn a_command_that_is_not_json_ends_a_ready_session() {
    let (outcome, _, _) = dispatch_one(&command_frame("mouseMove"), false);
    assert_eq!(outcome, ReadyOutcome::Close(CloseReason::MalformedPayload(MessageKind::Command)));
}

#[test]
fn an_unknown_key_inside_a_command_is_ignored_and_the_command_still_applies() {
    let (outcome, input, _) = dispatch_one(
        &command_frame(r#"{"mouseMove":{"to":{"x":0.25,"y":0.5},"futureField":true}}"#),
        false,
    );

    assert_eq!(outcome, ReadyOutcome::Dispatched(DispatchOutcome::Applied));
    assert_eq!(input.applied().len(), 1);
    assert!(matches!(
        input.applied()[0].0,
        RemoteCommand::MouseMove { to: NormalizedPoint { x, y } } if x == 0.25 && y == 0.5
    ));
}

#[test]
fn a_kind_the_host_does_not_implement_is_ignored_rather_than_closing_the_session() {
    let frame = Frame::new(MessageKind::ClipboardContent, b"{}".to_vec());
    let (outcome, _, _) = dispatch_one(&frame, false);
    assert_eq!(outcome, ReadyOutcome::Unhandled(MessageKind::ClipboardContent));
}

#[test]
fn observe_mode_refuses_pointer_and_keyboard_input_but_allows_quality_and_video_controls() {
    let blocked = [
        RemoteCommand::MouseMove { to: NormalizedPoint { x: 0.1, y: 0.1 } },
        RemoteCommand::MouseDown { button: MouseButton::Left },
        RemoteCommand::Scroll { dx: 0.0, dy: 3.0 },
        RemoteCommand::KeyDown { key_code: 0x41, modifiers: Modifiers::NONE },
        RemoteCommand::TextInput { text: "hi".to_owned() },
    ];
    for command in blocked {
        let (outcome, input, _) = dispatch_one(&command_frame(&serde_json::to_string(&command).expect("encodes")), true);
        assert_eq!(outcome, ReadyOutcome::Dispatched(DispatchOutcome::Ignored(IgnoreReason::ObserveMode)));
        assert!(input.applied().is_empty());
    }

    let allowed = [
        RemoteCommand::SetStreamQuality { fps: 30, bitrate_kbps: 4_000 },
        RemoteCommand::SetVideoEnabled { enabled: false },
        RemoteCommand::SetCaptureSource { source: CaptureSource::Display { id: 2 } },
    ];
    for command in allowed {
        let (outcome, _, source) = dispatch_one(&command_frame(&serde_json::to_string(&command).expect("encodes")), true);
        assert_eq!(outcome, ReadyOutcome::Dispatched(DispatchOutcome::Applied));
        assert_eq!(source.qualities.len() + source.video_enabled.len() + source.sources.len(), 1);
    }
}

#[test]
fn a_ready_session_still_answers_pings_in_observe_mode() {
    let mut host = paired_ready_host();
    assert_eq!(host.state(), HandshakeState::Ready);
    let ping = Frame::new(MessageKind::Ping, b"7".to_vec());
    assert!(host.on_frame(ping.clone()).contains(&SessionAction::ForwardFrame(ping.clone())));

    let (outcome, _, _) = dispatch_one(&ping, true);
    assert_eq!(outcome, ReadyOutcome::Reply(Frame::new(MessageKind::Pong, b"7".to_vec())));
}

#[test]
fn the_framing_refuses_a_zero_length_frame_an_unknown_kind_and_an_oversized_one() {
    let mut zero = FrameDecoder::new();
    zero.push(&[0, 0, 0, 0]);
    assert_eq!(zero.next_frame(), Err(FramingError::ZeroLength));

    let mut unknown = FrameDecoder::new();
    unknown.push(&[0, 0, 0, 1, 0x12]);
    assert_eq!(unknown.next_frame(), Err(FramingError::UnknownKind(0x12)));

    let mut oversized = FrameDecoder::new();
    let declared = MAX_FRAME_LENGTH + 1;
    oversized.push(&declared.to_be_bytes());
    assert_eq!(oversized.next_frame(), Err(FramingError::FrameTooLarge { declared }));
}
