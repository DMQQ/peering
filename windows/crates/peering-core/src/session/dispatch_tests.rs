use peering_wire::command::{MouseButton, Modifiers, WindowAction};
use peering_wire::source::NormalizedPoint;

use super::*;
use crate::fakes::input::RecordingInput;

#[derive(Default)]
struct RecordingSource {
    sources: Vec<CaptureSource>,
    qualities: Vec<(Option<u32>, Option<u32>)>,
    video_enabled: Vec<bool>,
    locks: usize,
}

impl SourceControl for RecordingSource {
    fn set_source(&mut self, source: CaptureSource) {
        self.sources.push(source);
    }

    fn set_quality(&mut self, fps: Option<u32>, bitrate_kbps: Option<u32>) {
        self.qualities.push((fps, bitrate_kbps));
    }

    fn set_video_enabled(&mut self, enabled: bool) {
        self.video_enabled.push(enabled);
    }

    fn lock_screen(&mut self) {
        self.locks += 1;
    }
}

fn transform() -> TransformSnapshot {
    TransformSnapshot { origin_x: 10, origin_y: 20, pixel_width: 1512, pixel_height: 982, scale: 2.0 }
}

fn run(command: RemoteCommand, observe_mode: bool) -> (DispatchOutcome, RecordingInput, RecordingSource) {
    let mut input = RecordingInput::default();
    let mut source = RecordingSource::default();
    let outcome = {
        let mut ctx = DispatchContext { observe_mode, transform: transform(), input: &mut input, source: &mut source };
        dispatch(command, &mut ctx)
    };
    (outcome, input, source)
}

fn frame_of(command: &RemoteCommand) -> Frame {
    Frame::new(MessageKind::Command, serde_json::to_vec(command).expect("command serialises"))
}

#[test]
fn pointer_and_key_input_reach_the_input_sink_with_the_transform() {
    let mouse = RemoteCommand::MouseMove { to: NormalizedPoint { x: 0.25, y: 0.5 } };
    let (outcome, input, _) = run(mouse.clone(), false);
    assert_eq!(outcome, DispatchOutcome::Applied);
    assert_eq!(input.applied(), &[(mouse, transform())]);

    let key = RemoteCommand::KeyDown { key_code: 36, modifiers: Modifiers::COMMAND };
    let (_, input, _) = run(key.clone(), false);
    assert_eq!(input.applied()[0].0, key);
}

#[test]
fn observe_mode_refuses_input_and_applies_nothing() {
    let (outcome, input, _) = run(RemoteCommand::MouseUp { button: MouseButton::Left }, true);
    assert_eq!(outcome, DispatchOutcome::Ignored(IgnoreReason::ObserveMode));
    assert!(input.applied().is_empty());
}

#[test]
fn observe_mode_still_allows_stream_and_session_controls() {
    let (outcome, _, source) = run(RemoteCommand::SetVideoEnabled { enabled: false }, true);
    assert_eq!(outcome, DispatchOutcome::Applied);
    assert_eq!(source.video_enabled, vec![false]);

    let (outcome, _, source) = run(RemoteCommand::LockScreen {}, true);
    assert_eq!(outcome, DispatchOutcome::Applied);
    assert_eq!(source.locks, 1);
}

#[test]
fn a_display_source_is_forwarded_to_source_control() {
    let (outcome, input, source) = run(RemoteCommand::SetCaptureSource { source: CaptureSource::Display { id: 4 } }, false);
    assert_eq!(outcome, DispatchOutcome::Applied);
    assert_eq!(source.sources, vec![CaptureSource::Display { id: 4 }]);
    assert!(input.applied().is_empty());
}

#[test]
fn a_mosaic_source_is_ignored_and_the_source_is_kept() {
    let mosaic = CaptureSource::Mosaic { layout: serde_json::json!({}) };
    let (outcome, _, source) = run(RemoteCommand::SetCaptureSource { source: mosaic }, false);
    assert_eq!(outcome, DispatchOutcome::Ignored(IgnoreReason::MosaicSource));
    assert!(source.sources.is_empty());
}

#[test]
fn quality_zero_means_keep_and_a_bitrate_is_capped() {
    let (_, _, source) = run(RemoteCommand::SetStreamQuality { fps: 0, bitrate_kbps: 200_000 }, false);
    assert_eq!(source.qualities, vec![(None, Some(100_000))]);

    let (_, _, source) = run(RemoteCommand::SetStreamQuality { fps: 60, bitrate_kbps: 0 }, false);
    assert_eq!(source.qualities, vec![(Some(60), None)]);
}

#[test]
fn negative_quality_values_are_treated_as_keep() {
    let (_, _, source) = run(RemoteCommand::SetStreamQuality { fps: -30, bitrate_kbps: -1 }, false);
    assert_eq!(source.qualities, vec![(None, None)]);
}

#[test]
fn an_enormous_frame_rate_does_not_wrap() {
    let (_, _, source) = run(RemoteCommand::SetStreamQuality { fps: i64::MAX, bitrate_kbps: 8_000 }, false);
    assert_eq!(source.qualities, vec![(Some(u32::MAX), Some(8_000))]);
}

#[test]
fn space_switching_is_ignored_even_when_not_observing() {
    let (outcome, input, _) = run(RemoteCommand::SwitchSpace { direction: peering_wire::command::SpaceDirection::Left }, false);
    assert_eq!(outcome, DispatchOutcome::Ignored(IgnoreReason::SpaceSwitch));
    assert!(input.applied().is_empty());

    let (outcome, _, _) = run(RemoteCommand::SwitchToSpace { display: 1, index: 2 }, false);
    assert_eq!(outcome, DispatchOutcome::Ignored(IgnoreReason::SpaceSwitch));
}

#[test]
fn virtual_display_privacy_window_and_launch_commands_are_ignored() {
    let cases = [
        (RemoteCommand::AddVirtualDisplay { name: "x".into(), width: 1, height: 1, start_landscape: false }, IgnoreReason::VirtualDisplay),
        (RemoteCommand::RemoveVirtualDisplay { display_id: 5 }, IgnoreReason::VirtualDisplay),
        (RemoteCommand::SetPrivacyMode { enabled: true }, IgnoreReason::PrivacyMode { enabled: true }),
        (RemoteCommand::PerformWindowAction { window_id: 7, action: WindowAction::Close }, IgnoreReason::WindowAction),
        (RemoteCommand::LaunchApplication { bundle_identifier: "x".into() }, IgnoreReason::Launch),
    ];
    for (command, reason) in cases {
        let (outcome, input, source) = run(command, false);
        assert_eq!(outcome, DispatchOutcome::Ignored(reason));
        assert!(input.applied().is_empty());
        assert!(source.sources.is_empty() && source.qualities.is_empty() && source.video_enabled.is_empty());
    }
}

#[test]
fn commands_without_a_port_here_are_ignored_without_panicking() {
    let (outcome, _, _) = run(RemoteCommand::RefreshSpacePreviews {}, false);
    assert_eq!(outcome, DispatchOutcome::Ignored(IgnoreReason::NotSupportedHere));
}

#[test]
fn the_requests_for_source_pictures_are_the_hosts_to_answer() {
    let (refresh, _, _) = run(RemoteCommand::RefreshSourceThumbnails {}, false);
    assert_eq!(refresh, DispatchOutcome::ForHost(RemoteCommand::RefreshSourceThumbnails {}));
    let (watch, _, _) = run(RemoteCommand::WatchSourceThumbnails { watching: true }, false);
    assert_eq!(watch, DispatchOutcome::ForHost(RemoteCommand::WatchSourceThumbnails { watching: true }));
}

#[test]
fn a_command_frame_is_decoded_and_dispatched() {
    let command = RemoteCommand::Scroll { dx: 0.0, dy: -12.5 };
    let mut input = RecordingInput::default();
    let mut source = RecordingSource::default();
    let mut ctx = DispatchContext { observe_mode: false, transform: transform(), input: &mut input, source: &mut source };
    let outcome = on_ready_frame(&frame_of(&command), &mut ctx);
    assert_eq!(outcome, ReadyOutcome::Dispatched(DispatchOutcome::Applied));
    assert_eq!(input.applied()[0].0, command);
}

#[test]
fn a_command_frame_that_does_not_decode_closes_the_session() {
    let mut input = RecordingInput::default();
    let mut source = RecordingSource::default();
    let mut ctx = DispatchContext { observe_mode: false, transform: transform(), input: &mut input, source: &mut source };
    let garbage = Frame::new(MessageKind::Command, b"{\"noSuchCommand\":{}}".to_vec());
    assert_eq!(on_ready_frame(&garbage, &mut ctx), ReadyOutcome::Close(CloseReason::MalformedPayload(MessageKind::Command)));
    assert!(input.applied().is_empty());
}

#[test]
fn an_oversized_command_frame_closes_the_session() {
    let mut input = RecordingInput::default();
    let mut source = RecordingSource::default();
    let mut ctx = DispatchContext { observe_mode: false, transform: transform(), input: &mut input, source: &mut source };
    let oversized = Frame::new(MessageKind::Command, vec![b' '; MAX_CONTROL_PAYLOAD + 1]);
    assert_eq!(on_ready_frame(&oversized, &mut ctx), ReadyOutcome::Close(CloseReason::MalformedPayload(MessageKind::Command)));
}

#[test]
fn a_ping_is_answered_with_a_pong_echoing_its_payload() {
    let mut input = RecordingInput::default();
    let mut source = RecordingSource::default();
    let mut ctx = DispatchContext { observe_mode: false, transform: transform(), input: &mut input, source: &mut source };
    let ping = Frame::new(MessageKind::Ping, b"{\"sequence\":12}".to_vec());
    assert_eq!(on_ready_frame(&ping, &mut ctx), ReadyOutcome::Reply(Frame::new(MessageKind::Pong, b"{\"sequence\":12}".to_vec())));
}

#[test]
fn other_kinds_are_left_unhandled_rather_than_closing_the_session() {
    let mut input = RecordingInput::default();
    let mut source = RecordingSource::default();
    let mut ctx = DispatchContext { observe_mode: false, transform: transform(), input: &mut input, source: &mut source };
    assert_eq!(
        on_ready_frame(&Frame::empty(MessageKind::VideoKeyRequest), &mut ctx),
        ReadyOutcome::Unhandled(MessageKind::VideoKeyRequest)
    );
}

#[test]
fn clipboard_commands_are_handed_to_the_host_untouched() {
    for command in [
        RemoteCommand::RequestClipboard {},
        RemoteCommand::PushClipboard { text: "x".into() },
        RemoteCommand::PushClipboardImage { png: vec![1, 2] },
    ] {
        let (outcome, input, _) = run(command.clone(), false);
        assert_eq!(outcome, DispatchOutcome::ForHost(command));
        assert!(input.applied().is_empty());
    }
}

#[test]
fn an_assembled_command_may_exceed_the_single_frame_limit() {
    let command = RemoteCommand::PushClipboard { text: "x".repeat(MAX_CONTROL_PAYLOAD * 2) };
    let mut input = RecordingInput::default();
    let mut source = RecordingSource::default();
    let mut ctx = DispatchContext { observe_mode: false, transform: transform(), input: &mut input, source: &mut source };
    assert_eq!(on_assembled_command(&frame_of(&command), &mut ctx), ReadyOutcome::Dispatched(DispatchOutcome::ForHost(command.clone())));
    assert!(matches!(on_ready_frame(&frame_of(&command), &mut ctx), ReadyOutcome::Close(_)), "a single frame that large is refused");
}

#[test]
fn an_assembled_frame_that_is_not_a_command_is_left_unhandled() {
    let mut input = RecordingInput::default();
    let mut source = RecordingSource::default();
    let mut ctx = DispatchContext { observe_mode: false, transform: transform(), input: &mut input, source: &mut source };
    let other = Frame::new(MessageKind::ClipboardContent, b"{}".to_vec());
    assert_eq!(on_assembled_command(&other, &mut ctx), ReadyOutcome::Unhandled(MessageKind::ClipboardContent));
}
