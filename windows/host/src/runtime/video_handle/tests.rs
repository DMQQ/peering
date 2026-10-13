use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread;

use peering_core::fakes::capture::FakeCapture;
use peering_core::fakes::encoder::FakeEncoder;
use peering_core::ports::capture::{Capture, CaptureError, DisplayInfo, RawFrame};
use peering_core::ports::encoder::{EncodeError, EncodedOutput, Encoder};

use super::*;
use crate::runtime::RebuildVideo;

fn display(id: u32, is_primary: bool) -> DisplayInfo {
    DisplayInfo { id, name: format!("Display {id}"), pixel_width: 1920, pixel_height: 1080, origin_x: 0, origin_y: 0, scale: 1.0, is_primary }
}

/// Holds an encode until the test lets it go, like a stalled hardware encoder.
struct Gated {
    inner: FakeEncoder,
    entered: Sender<()>,
    release: Receiver<()>,
}

impl Encoder for Gated {
    fn configure(&mut self, width: u32, height: u32, fps: u32, bitrate_bps: u32) -> Result<(), EncodeError> {
        self.inner.configure(width, height, fps, bitrate_bps)
    }

    fn encode(&mut self, frame: &RawFrame, force_keyframe: bool) -> Result<Vec<EncodedOutput>, EncodeError> {
        let _ = self.entered.send(());
        let _ = self.release.recv();
        self.inner.encode(frame, force_keyframe)
    }

    fn set_bitrate(&mut self, bitrate_bps: u32) {
        self.inner.set_bitrate(bitrate_bps);
    }
}

/// A capture the test can push frames into after the coordinator owns it.
struct SharedFake(Arc<Mutex<FakeCapture>>);

impl Capture for SharedFake {
    fn list_displays(&self) -> Vec<DisplayInfo> {
        self.0.lock().expect("the capture is not poisoned").list_displays()
    }

    fn start(&mut self, display_id: u32) -> Result<(), CaptureError> {
        self.0.lock().expect("the capture is not poisoned").start(display_id)
    }

    fn stop(&mut self) {
        self.0.lock().expect("the capture is not poisoned").stop();
    }

    fn poll_frame(&mut self) -> Option<RawFrame> {
        self.0.lock().expect("the capture is not poisoned").poll_frame()
    }
}

fn source(id: u32) -> CaptureSource {
    CaptureSource::Display { id }
}

struct Rig {
    handle: VideoHandle,
    capture: Arc<Mutex<FakeCapture>>,
    entered: Receiver<()>,
    release: Sender<()>,
}

fn rig() -> Rig {
    let (entered_sender, entered) = channel();
    let (release, release_receiver) = channel();
    let capture = Arc::new(Mutex::new(FakeCapture::new(vec![display(1, true), display(2, false)])));
    let gated = Gated { inner: FakeEncoder::default(), entered: entered_sender, release: release_receiver };
    let shared = SharedCapture::new(Box::new(SharedFake(capture.clone())));
    let coordinator = VideoCoordinator::new(shared.clone(), BoxedEncoder(Box::new(gated)));
    let rebuild: RebuildVideo = {
        let capture = capture.clone();
        Arc::new(move || (Box::new(SharedFake(capture.clone())), Box::new(FakeEncoder::default())))
    };
    Rig { handle: VideoHandle::new(coordinator, shared, rebuild), capture, entered, release }
}

fn registered(rig: &Rig) {
    rig.handle.request(VideoIntent::Attach("phone".to_owned()));
    rig.handle.apply(VideoIntent::EnsureCapturing, 1.0).expect("the primary display starts");
    rig.capture.lock().expect("the capture is not poisoned").push_frame(RawFrame { width: 1920, height: 1080, sequence: 1 });
}

#[test]
fn a_registration_and_a_source_change_during_an_encode_do_not_wait_for_it() {
    let rig = rig();
    registered(&rig);
    let pumping = rig.handle.clone();
    let encode = thread::spawn(move || pumping.pump(2.0));
    rig.entered.recv().expect("the encode started");

    rig.handle.request(VideoIntent::Attach("second".to_owned()));
    let deferred = rig.handle.apply(VideoIntent::SetSource(source(2)), 2.0);

    assert!(deferred.is_ok(), "the request is recorded, not refused");
    assert_eq!(rig.handle.running_source(), Some(source(1)), "nothing changed while the encode held the coordinator");
    rig.release.send(()).expect("the encode is waiting");
    encode.join().expect("the pass ends").expect("the pass does not panic").expect("the encode succeeds");
    assert_eq!(rig.handle.running_source(), Some(source(2)), "the change was applied when the pass finished");
}

#[test]
fn a_setting_asked_for_during_an_encode_is_readable_after_it() {
    let rig = rig();
    registered(&rig);
    let pumping = rig.handle.clone();
    let encode = thread::spawn(move || pumping.pump(2.0));
    rig.entered.recv().expect("the encode started");

    rig.handle.request(VideoIntent::SetBitrateCeiling(Some(1_500)));
    rig.handle.request(VideoIntent::SetFrameRate(30));
    rig.release.send(()).expect("the encode is waiting");
    let _outcome = encode.join().expect("the pass ends");

    assert_eq!(rig.handle.bitrate_ceiling_kbps(), Some(1_500));
    assert_eq!(rig.handle.frame_rate(), 30);
}

#[test]
fn an_idle_handle_applies_a_request_at_once() {
    let rig = rig();
    registered(&rig);
    rig.handle.apply(VideoIntent::SetSource(source(2)), 3.0).expect("the display exists");
    assert_eq!(rig.handle.running_source(), Some(source(2)));
}

#[test]
fn a_pass_past_its_deadline_is_replaced_with_the_clients_and_settings_it_held() {
    let rig = rig();
    registered(&rig);
    rig.handle.request(VideoIntent::SetFrameRate(30));
    let pumping = rig.handle.clone();
    let stuck = thread::spawn(move || pumping.pump(2.0));
    rig.entered.recv().expect("the encode started");
    rig.handle.request(VideoIntent::Attach("second".to_owned()));
    assert!(!rig.handle.pass_overdue(11.9));
    assert!(rig.handle.pass_overdue(12.0));

    rig.handle.abandon_pass(12.0).expect("the display starts on the new device");

    assert_eq!(rig.handle.running_source(), Some(source(1)));
    assert_eq!(rig.handle.frame_rate(), 30);
    assert_eq!(rig.handle.capture_condition(), Some(CaptureCondition::Recovering));
    assert!(!rig.handle.pass_overdue(1_000.0), "the abandoned pass is no longer watched");
    rig.release.send(()).expect("the stuck encode is waiting");
    stuck.join().expect("the stuck thread ends").expect("it does not panic").expect("its encode finishes");
    assert_eq!(rig.handle.frame_rate(), 30, "the late return did not put the old coordinator back");
    assert_eq!(rig.handle.capture_condition(), Some(CaptureCondition::Recovering));
}

#[test]
fn abandoning_when_no_pass_is_running_changes_nothing() {
    let rig = rig();
    registered(&rig);
    rig.handle.abandon_pass(50.0).expect("nothing to replace");
    assert_eq!(rig.handle.capture_condition(), None);
}
