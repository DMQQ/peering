use super::*;
use crate::fakes::capture::FakeCapture;
use crate::fakes::encoder::FakeEncoder;
use crate::ports::capture::{CaptureError, DisplayInfo, RawFrame, WindowInfo};

fn display() -> DisplayInfo {
    DisplayInfo {
        id: 1,
        name: "Display 1".to_owned(),
        pixel_width: 1920,
        pixel_height: 1080,
        origin_x: 0,
        origin_y: 0,
        scale: 1.0,
        is_primary: true,
    }
}

fn window(id: u32, width: u32, height: u32) -> WindowInfo {
    WindowInfo {
        id,
        title: "Notes".to_owned(),
        application: "Notepad".to_owned(),
        pixel_width: width,
        pixel_height: height,
        origin_x: 10,
        origin_y: 20,
        scale: 1.0,
    }
}

fn coordinator_with(windows: Vec<WindowInfo>) -> VideoCoordinator<FakeCapture, FakeEncoder> {
    let mut capture = FakeCapture::new(vec![display()]);
    capture.set_windows(windows);
    VideoCoordinator::new(capture, FakeEncoder::default())
}

fn window_source(id: u32) -> CaptureSource {
    CaptureSource::Window { id }
}

#[test]
fn a_window_that_can_be_captured_becomes_the_source_at_its_own_size() {
    let mut coordinator = coordinator_with(vec![window(7, 801, 601)]);
    coordinator.set_source(window_source(7), 0.0).unwrap();
    assert_eq!(coordinator.running_source(), Some(&window_source(7)));
    assert_eq!(coordinator.capture.running_window(), Some(7));
    assert_eq!(coordinator.size, (800, 600), "the encoder takes even sides");
}

#[test]
fn a_window_that_is_not_listed_is_refused_and_nothing_changes() {
    let mut coordinator = coordinator_with(Vec::new());
    coordinator.set_source(CaptureSource::Display { id: 1 }, 0.0).unwrap();
    let error = coordinator.set_source(window_source(7), 1.0).unwrap_err();
    assert!(matches!(error, CoordinatorError::Capture(CaptureError::WindowNotFound(7))));
    assert_eq!(coordinator.chosen_source(), Some(&CaptureSource::Display { id: 1 }));
}

#[test]
fn switching_from_a_window_back_to_a_display_stops_the_window_capture() {
    let mut coordinator = coordinator_with(vec![window(7, 800, 600)]);
    coordinator.set_source(window_source(7), 0.0).unwrap();
    coordinator.set_source(CaptureSource::Display { id: 1 }, 1.0).unwrap();
    assert_eq!(coordinator.capture.running_window(), None);
    assert_eq!(coordinator.capture.running_display(), Some(1));
}

#[test]
fn the_description_of_a_window_names_the_window_as_its_source() {
    let mut coordinator = coordinator_with(vec![window(7, 800, 600)]);
    coordinator.set_source(window_source(7), 0.0).unwrap();
    coordinator.attach("phone");
    coordinator.capture.push_frame(RawFrame { width: 800, height: 600, sequence: 1 });
    let outputs = coordinator.pump(0.1).unwrap();
    let source_ids: Vec<&str> = outputs
        .iter()
        .filter_map(|output| match output {
            VideoOutput::Config(config) => Some(config.source_id.as_str()),
            VideoOutput::Frame(_) => None,
        })
        .collect();
    assert_eq!(source_ids, ["window:7"]);
}

#[test]
fn a_window_that_closes_while_captured_moves_the_picture_to_the_display() {
    let mut coordinator = coordinator_with(vec![window(7, 800, 600)]);
    coordinator.set_source(window_source(7), 0.0).unwrap();
    coordinator.attach("phone");
    coordinator.capture.fail();
    coordinator.capture.set_windows(Vec::new());
    coordinator.pump(1.0).unwrap();
    coordinator.pump(5.0).unwrap();
    assert_eq!(coordinator.running_source(), Some(&CaptureSource::Display { id: 1 }));
    assert_eq!(coordinator.capture.running_display(), Some(1));
}

#[test]
fn a_window_that_is_still_there_is_restarted_when_its_capture_fails() {
    let mut coordinator = coordinator_with(vec![window(7, 800, 600)]);
    coordinator.set_source(window_source(7), 0.0).unwrap();
    coordinator.attach("phone");
    let starts = coordinator.capture.starts();
    coordinator.capture.fail();
    coordinator.pump(1.0).unwrap();
    coordinator.pump(5.0).unwrap();
    assert_eq!(coordinator.running_source(), Some(&window_source(7)));
    assert!(coordinator.capture.starts() > starts);
}
