mod support;

use peering_core::ports::capture::{RawFrame, WindowInfo};
use peering_core::ports::clock::Clock;
use peering_wire::command::RemoteCommand;
use peering_wire::framing::MessageKind;
use peering_wire::source::{CaptureCatalog, CaptureSource};
use peering_wire::video::VideoStreamConfig;
use support::*;

fn notepad() -> WindowInfo {
    WindowInfo {
        id: 4242,
        title: "notes.txt - Notepad".to_owned(),
        application: "Notepad".to_owned(),
        pixel_width: 800,
        pixel_height: 600,
        origin_x: 200,
        origin_y: 100,
        scale: 1.0,
    }
}

fn windows_on(harness: &Harness, windows: Vec<WindowInfo>) {
    harness.capture.lock().expect("the capture is not poisoned").set_windows(windows);
}

#[test]
fn a_window_that_can_be_captured_is_in_the_catalogue_and_one_that_cannot_is_not() {
    run(async {
        let harness = harness();
        windows_on(&harness, vec![notepad()]);
        let mut phone = paired_phone(&harness.runtime).await;
        let catalogue: CaptureCatalog = decode_json(&phone.next_of(MessageKind::Catalog).await);
        assert_eq!(catalogue.windows.len(), 1);
        assert_eq!(catalogue.windows[0].id, "window:4242");
        assert_eq!(catalogue.windows[0].title, "notes.txt - Notepad");
        assert_eq!(catalogue.windows[0].subtitle.as_deref(), Some("Notepad"));
        assert!(catalogue.applications.is_empty());
    });
}

#[test]
fn choosing_a_window_streams_it_and_maps_the_pointer_into_it() {
    run(async {
        let harness = harness();
        windows_on(&harness, vec![notepad()]);
        let mut phone = paired_phone(&harness.runtime).await;
        phone.next_of(MessageKind::Catalog).await;

        phone.send_command(&RemoteCommand::SetCaptureSource { source: CaptureSource::Window { id: 4242 } }).await;
        phone.sync().await;
        assert_eq!(harness.capture.lock().expect("the capture is not poisoned").running_window(), Some(4242));

        harness
            .capture
            .lock()
            .expect("the capture is not poisoned")
            .push_frame(RawFrame { width: 800, height: 600, sequence: 1 });
        harness.runtime.pump_video(harness.clock.now_seconds()).expect("the pump runs");
        let config: VideoStreamConfig = decode_json(&phone.next_of(MessageKind::VideoConfig).await);
        assert_eq!(config.source_id, "window:4242");

        phone.send_command(&mouse_move(0.5, 0.5)).await;
        phone.sync().await;
        let input = harness.input.lock().expect("the input is not poisoned");
        let (_, transform) = input
            .applied()
            .iter()
            .rev()
            .find(|(command, _)| matches!(command, RemoteCommand::MouseMove { .. }))
            .expect("the move reached the input");
        assert_eq!((transform.origin_x, transform.origin_y), (200, 100));
        assert_eq!((transform.pixel_width, transform.pixel_height), (800, 600));
    });
}

#[test]
fn a_window_that_is_not_listed_is_refused_and_the_display_carries_on() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        phone.next_of(MessageKind::Catalog).await;

        phone.send_command(&RemoteCommand::SetCaptureSource { source: CaptureSource::Window { id: 7 } }).await;
        phone.sync().await;
        assert_eq!(harness.capture.lock().expect("the capture is not poisoned").running_window(), None);
        assert_eq!(harness.capture.lock().expect("the capture is not poisoned").running_display(), Some(1));
    });
}
