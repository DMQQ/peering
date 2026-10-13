//! Switching the displayed screen: the catalogue each session is sent, the one new stream description a switch
//! produces, the input mapping that follows the active display, and what a switch to a missing display does.

mod common;

use common::*;
use peering_core::catalogue::{CatalogueService, SessionCatalogue};
use peering_core::ports::capture::DisplayInfo;
use peering_core::session::dispatch::{dispatch, DispatchContext};
use peering_core::fakes::input::RecordingInput;
use peering_core::ports::input::TransformSnapshot;
use peering_wire::command::RemoteCommand;
use peering_wire::source::{CaptureSource, NormalizedPoint};
use peering_wire::transform::InputTransform;
use peering_core::video::coordinator::VideoOutput;

fn two_displays() -> Vec<DisplayInfo> {
    vec![display_info(1, true), display_info(2, false)]
}

fn transform_of(display: &DisplayInfo) -> TransformSnapshot {
    TransformSnapshot {
        origin_x: display.origin_x,
        origin_y: display.origin_y,
        pixel_width: display.pixel_width,
        pixel_height: display.pixel_height,
        scale: display.scale,
    }
}

fn configs(outputs: &[VideoOutput]) -> Vec<String> {
    outputs
        .iter()
        .filter_map(|output| match output {
            VideoOutput::Config(config) => Some(config.source_id.clone()),
            VideoOutput::Frame(_) => None,
        })
        .collect()
}

#[test]
fn the_catalogue_is_pushed_once_to_each_session_and_again_only_when_the_displays_change() {
    let mut catalogue = CatalogueService::new();
    let mut sent = SessionCatalogue::new();
    let first = catalogue.update(&two_displays()).expect("the first catalogue");

    assert!(sent.due(&"phone-a", &first).is_some());
    assert!(sent.due(&"phone-a", &first).is_none(), "the same session is not sent it twice");
    assert!(sent.due(&"phone-b", &first).is_some(), "another session still needs its own copy");

    assert!(catalogue.update(&two_displays()).is_none(), "an unchanged set of displays changes nothing");
    let grown = catalogue
        .update(&[two_displays(), vec![display_info(3, false)]].concat())
        .expect("a new display changes the catalogue");
    assert!(sent.due(&"phone-a", &grown).is_some());
    assert_eq!(grown.displays.len(), 3);
}

#[test]
fn switching_the_display_produces_one_new_description_with_a_new_source_id() {
    let (mut coordinator, capture, _encoder) = shared_coordinator(two_displays());
    coordinator.attach("phone-a");
    coordinator.set_source(CaptureSource::Display { id: 1 }, 0.0).expect("display 1");
    locked(&capture).push_frame(raw_frame(1));
    assert_eq!(configs(&coordinator.pump(0.0).expect("picture")), ["display:1"]);

    coordinator.set_source(CaptureSource::Display { id: 2 }, 1.0).expect("display 2");
    locked(&capture).push_frame(raw_frame(2));
    locked(&capture).push_frame(raw_frame(3));
    let after_switch = coordinator.pump(1.1).expect("pictures after the switch");

    assert_eq!(configs(&after_switch), ["display:2"], "exactly one new description, with the new source");
    assert_eq!(coordinator.running_source(), Some(&CaptureSource::Display { id: 2 }));
}

#[test]
fn choosing_the_display_already_showing_changes_nothing() {
    let (mut coordinator, capture, _encoder) = shared_coordinator(two_displays());
    coordinator.attach("phone-a");
    coordinator.set_source(CaptureSource::Display { id: 1 }, 0.0).expect("display 1");
    locked(&capture).push_frame(raw_frame(1));
    coordinator.pump(0.0).expect("picture");

    coordinator.set_source(CaptureSource::Display { id: 1 }, 0.5).expect("the same display");
    locked(&capture).push_frame(raw_frame(2));
    let outputs = coordinator.pump(0.6).expect("picture");

    assert!(configs(&outputs).is_empty());
}

#[test]
fn input_maps_through_the_display_that_is_showing_after_a_switch() {
    let (mut coordinator, _capture, _encoder) = shared_coordinator(two_displays());
    coordinator.attach("phone-a");
    coordinator.set_source(CaptureSource::Display { id: 2 }, 0.0).expect("display 2");
    let active = two_displays().into_iter().find(|display| display.id == 2).expect("display 2 exists");
    let mut control = CoordinatorControl { coordinator, now: 0.0, rejected: Vec::new() };
    let mut input = RecordingInput::default();
    let mut ctx = DispatchContext {
        observe_mode: false,
        transform: transform_of(&active),
        input: &mut input,
        source: &mut control,
    };

    dispatch(RemoteCommand::MouseMove { to: NormalizedPoint { x: 0.5, y: 0.5 } }, &mut ctx);

    let (_, snapshot) = input.applied().first().cloned().expect("the move was applied");
    let mapped = InputTransform {
        origin_x: f64::from(snapshot.origin_x),
        origin_y: f64::from(snapshot.origin_y),
        pixel_width: f64::from(snapshot.pixel_width),
        pixel_height: f64::from(snapshot.pixel_height),
        scale: snapshot.scale,
    }
    .global_point(0.5, 0.5);
    assert_eq!(mapped, (1512.0 + 378.0, 245.5), "the centre of display 2, which starts at x 1512");
}

#[test]
fn a_switch_to_a_display_that_is_not_attached_is_refused_and_the_picture_carries_on() {
    let (mut coordinator, capture, _encoder) = shared_coordinator(two_displays());
    coordinator.attach("phone-a");
    coordinator.set_source(CaptureSource::Display { id: 1 }, 0.0).expect("display 1");
    locked(&capture).push_frame(raw_frame(1));
    coordinator.pump(0.0).expect("picture");

    let refused = coordinator.set_source(CaptureSource::Display { id: 9 }, 0.5);
    assert!(refused.is_err());
    assert_eq!(coordinator.running_source(), Some(&CaptureSource::Display { id: 1 }));

    let mut control = CoordinatorControl { coordinator, now: 0.5, rejected: Vec::new() };
    dispatch_switch(&mut control, CaptureSource::Display { id: 9 });
    assert_eq!(control.rejected, ["display 9 is not attached"]);
    locked(&capture).push_frame(raw_frame(2));
    let outputs = control.coordinator.pump(0.6).expect("pumping after the refusal");
    assert!(configs(&outputs).is_empty(), "no new description was produced");
    assert_eq!(control.coordinator.running_source(), Some(&CaptureSource::Display { id: 1 }));
}

#[test]
fn an_application_is_refused_as_a_capture_source_without_changing_the_display() {
    let (mut coordinator, _capture, _encoder) = shared_coordinator(two_displays());
    coordinator.attach("phone-a");
    coordinator.set_source(CaptureSource::Display { id: 1 }, 0.0).expect("display 1");
    let mut control = CoordinatorControl { coordinator, now: 0.0, rejected: Vec::new() };

    dispatch_switch(&mut control, CaptureSource::Application { pid: 5 });

    assert_eq!(control.rejected, ["only display and window sources can be captured, not application:5"]);
    assert_eq!(control.coordinator.running_source(), Some(&CaptureSource::Display { id: 1 }));
}

fn dispatch_switch(control: &mut CoordinatorControl, source: CaptureSource) {
    let mut input = RecordingInput::default();
    let mut ctx = dispatch_context(&mut input, control, false);
    dispatch(RemoteCommand::SetCaptureSource { source }, &mut ctx);
}
