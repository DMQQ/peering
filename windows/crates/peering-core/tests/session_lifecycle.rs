//! Clients attach to and leave a running video session: what each new client is sent, what stops when the last one
//! goes, and what a pause and resume look like on the wire.

mod common;

use common::*;
use peering_core::fakes::input::RecordingInput;
use peering_core::ports::input::TransformSnapshot;
use peering_core::session::dispatch::{dispatch, DispatchContext};
use peering_core::session::held_input::{HeldInput, TrackedInput};
use peering_core::ports::capture::RawFrame;
use peering_core::video::coordinator::VideoOutput;
use peering_wire::command::RemoteCommand;
use peering_wire::source::CaptureSource;

fn watching_display_one() -> (TestCoordinator, CaptureHandle, EncoderHandle) {
    let (mut coordinator, capture, encoder) = shared_coordinator(vec![display_info(1, true), display_info(2, false)]);
    coordinator.attach("client-a");
    coordinator.set_source(CaptureSource::Display { id: 1 }, 0.0).expect("display 1 is attached");
    (coordinator, capture, encoder)
}

#[test]
fn the_first_client_is_sent_the_stream_description_and_a_keyframe() {
    let (mut coordinator, capture, _encoder) = watching_display_one();
    locked_push(&capture, raw_frame(1));

    let outputs = coordinator.pump(0.0).expect("pumping encodes the frame");

    let config = config_of(&outputs).expect("a stream description comes first");
    assert_eq!(config.source_id, "display:1");
    assert_eq!((config.pixel_width, config.pixel_height), (1512, 982));
    assert_eq!(keyframe_of(&outputs), Some(true));
}

#[test]
fn a_client_joining_a_running_stream_is_sent_a_description_and_a_keyframe_again() {
    let (mut coordinator, capture, _encoder) = watching_display_one();
    locked_push(&capture, raw_frame(1));
    coordinator.pump(0.0).expect("first picture");

    coordinator.attach("client-b");
    locked_push(&capture, raw_frame(2));
    let outputs = coordinator.pump(0.1).expect("second picture");

    assert!(config_of(&outputs).is_some(), "the new client needs the description again");
    assert_eq!(keyframe_of(&outputs), Some(true), "and a recovery point before any delta frame");
}

#[test]
fn nothing_is_encoded_once_the_last_client_has_left_but_the_capture_stays_running() {
    let (mut coordinator, capture, encoder) = watching_display_one();
    locked_push(&capture, raw_frame(1));
    coordinator.pump(0.0).expect("picture while watched");
    let encoded_while_watched = locked(&encoder).encode_calls().len();

    coordinator.detach("client-a");
    locked_push(&capture, raw_frame(2));
    let outputs = coordinator.pump(0.1).expect("pumping with nobody attached");

    assert!(outputs.is_empty());
    assert_eq!(locked(&encoder).encode_calls().len(), encoded_while_watched);
    assert_eq!(coordinator.running_source(), Some(&CaptureSource::Display { id: 1 }));
}

#[test]
fn the_next_client_does_not_inherit_the_source_the_last_one_chose() {
    let (mut coordinator, _capture, _encoder) = watching_display_one();
    coordinator.set_source(CaptureSource::Display { id: 2 }, 1.0).expect("display 2 is attached");
    coordinator.detach("client-a");

    coordinator.forget_chosen_source_if_idle();

    assert_eq!(coordinator.chosen_source(), None);
    assert_eq!(
        coordinator.running_source(),
        Some(&CaptureSource::Display { id: 2 }),
        "capture keeps the display, so a client that returns soon gets a picture without a restart"
    );
    coordinator.attach("client-b");
    assert_eq!(coordinator.chosen_source(), None);
}

#[test]
fn forgetting_the_choice_while_a_client_remains_keeps_it() {
    let (mut coordinator, _capture, _encoder) = watching_display_one();
    coordinator.attach("client-b");
    coordinator.set_source(CaptureSource::Display { id: 2 }, 1.0).expect("display 2 is attached");
    coordinator.detach("client-a");

    coordinator.forget_chosen_source_if_idle();

    assert_eq!(coordinator.chosen_source(), Some(&CaptureSource::Display { id: 2 }));
}

#[test]
fn a_disconnect_releases_the_keys_and_buttons_the_client_left_down() {
    let (coordinator, _capture, _encoder) = watching_display_one();
    let mut control = CoordinatorControl { coordinator, now: 0.0, rejected: Vec::new() };
    let mut input = RecordingInput::default();
    let mut held = HeldInput::default();
    let transform = TransformSnapshot { origin_x: 0, origin_y: 0, pixel_width: 1512, pixel_height: 982, scale: 2.0 };
    {
        let mut tracked = TrackedInput::new(&mut input, &mut held);
        let mut ctx = DispatchContext { observe_mode: false, transform, input: &mut tracked, source: &mut control };
        dispatch(RemoteCommand::KeyDown { key_code: 0x10, modifiers: peering_wire::command::Modifiers::NONE }, &mut ctx);
    }
    assert_eq!(input.applied().len(), 1);

    held.release_held(&transform, &mut input);

    assert_eq!(input.applied().len(), 2, "the held key is released explicitly");
    assert_eq!(input.release_all_count(), 1);
}

#[test]
fn pausing_sends_nothing_and_resuming_sends_a_description_and_a_keyframe() {
    let (coordinator, capture, encoder) = watching_display_one();
    let mut control = CoordinatorControl { coordinator, now: 0.0, rejected: Vec::new() };
    let mut input = RecordingInput::default();
    locked_push(&capture, raw_frame(1));
    control.coordinator.pump(0.0).expect("picture before the pause");

    {
        let mut ctx = dispatch_context(&mut input, &mut control, false);
        dispatch(RemoteCommand::SetVideoEnabled { enabled: false }, &mut ctx);
    }
    locked_push(&capture, raw_frame(2));
    let paused = control.coordinator.pump(0.1).expect("pumping while paused");
    assert!(paused.is_empty());
    assert_eq!(locked(&encoder).encode_calls().len(), 1, "frames captured while paused are not encoded");

    {
        let mut ctx = dispatch_context(&mut input, &mut control, false);
        dispatch(RemoteCommand::SetVideoEnabled { enabled: true }, &mut ctx);
    }
    locked_push(&capture, raw_frame(3));
    let resumed = control.coordinator.pump(0.2).expect("pumping after resume");

    assert!(config_of(&resumed).is_some());
    assert_eq!(keyframe_of(&resumed), Some(true));
    assert_eq!(locked(&encoder).encode_calls().last(), Some(&(3, true)), "the resumed frame is forced to a keyframe");
    assert!(resumed.iter().all(|output| matches!(output, VideoOutput::Config(_) | VideoOutput::Frame(_))));
}

#[test]
fn a_bitrate_change_reaches_the_encoder_through_the_dispatcher() {
    let (coordinator, _capture, encoder) = watching_display_one();
    let mut control = CoordinatorControl { coordinator, now: 0.0, rejected: Vec::new() };
    let mut input = RecordingInput::default();
    let mut ctx = dispatch_context(&mut input, &mut control, false);
    dispatch(RemoteCommand::SetStreamQuality { fps: 0, bitrate_kbps: 4_000 }, &mut ctx);

    assert_eq!(locked(&encoder).bitrate_calls().last(), Some(&4_000_000));
}

fn locked_push(capture: &CaptureHandle, frame: RawFrame) {
    locked(capture).push_frame(frame);
}
