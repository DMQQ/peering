use super::*;
use crate::fakes::capture::FakeCapture;
use crate::fakes::encoder::FakeEncoder;
use crate::ports::capture::DisplayInfo;
use crate::video::coordinator::CaptureCondition;

type Coordinator = VideoCoordinator<FakeCapture, FakeEncoder>;

fn display(id: u32, is_primary: bool) -> DisplayInfo {
    DisplayInfo {
        id,
        name: format!("Display {id}"),
        pixel_width: 1920,
        pixel_height: 1080,
        origin_x: 0,
        origin_y: 0,
        scale: 1.0,
        is_primary,
    }
}

fn coordinator() -> Coordinator {
    VideoCoordinator::new(FakeCapture::new(vec![display(1, true), display(2, false)]), FakeEncoder::default())
}

fn source(id: u32) -> CaptureSource {
    CaptureSource::Display { id }
}

fn apply_all(queue: &mut IntentQueue, coordinator: &mut Coordinator, now: f64) {
    for intent in queue.take() {
        intent.apply(coordinator, now).expect("the intent applies");
    }
}

#[test]
fn a_registration_and_a_source_change_wait_in_order_and_apply_together() {
    let mut queue = IntentQueue::default();
    queue.push(VideoIntent::Attach("phone".to_owned()));
    queue.push(VideoIntent::EnsureCapturing);
    queue.push(VideoIntent::SetSource(source(2)));
    assert_eq!(queue.len(), 3);

    let mut coordinator = coordinator();
    apply_all(&mut queue, &mut coordinator, 1.0);

    assert!(queue.is_empty());
    assert_eq!(coordinator.running_source(), Some(&source(2)));
}

#[test]
fn a_setting_asked_for_twice_keeps_only_the_later_value() {
    let mut queue = IntentQueue::default();
    queue.push(VideoIntent::SetSource(source(1)));
    queue.push(VideoIntent::SetFrameRate(30));
    queue.push(VideoIntent::SetSource(source(2)));
    queue.push(VideoIntent::Resync);
    queue.push(VideoIntent::Resync);

    let kept = queue.take();

    assert_eq!(kept, [VideoIntent::SetFrameRate(30), VideoIntent::SetSource(source(2)), VideoIntent::Resync]);
}

#[test]
fn attaches_and_detaches_are_never_dropped() {
    let mut queue = IntentQueue::default();
    queue.push(VideoIntent::Attach("a".to_owned()));
    queue.push(VideoIntent::Detach("a".to_owned()));
    queue.push(VideoIntent::Attach("a".to_owned()));
    assert_eq!(queue.len(), 3);
}

#[test]
fn a_fresh_coordinator_is_given_the_clients_settings_and_display_of_the_lost_one() {
    let mut desired = VideoDesired::default();
    for intent in [
        VideoIntent::Attach("phone".to_owned()),
        VideoIntent::SetSource(source(2)),
        VideoIntent::SetFrameRate(30),
        VideoIntent::SetBitrateCeiling(Some(1_500)),
    ] {
        desired.note(&intent);
    }

    let mut fresh = coordinator();
    desired.restore(&mut fresh, 5.0).expect("the display is there");

    assert_eq!(fresh.running_source(), Some(&source(2)));
    assert_eq!(fresh.frame_rate(), 30);
    assert_eq!(fresh.bitrate_ceiling_kbps(), Some(1_500));
}

#[test]
fn nothing_is_captured_for_a_fresh_coordinator_when_every_client_has_left() {
    let mut desired = VideoDesired::default();
    desired.note(&VideoIntent::Attach("phone".to_owned()));
    desired.note(&VideoIntent::SetSource(source(2)));
    desired.note(&VideoIntent::Detach("phone".to_owned()));
    desired.note(&VideoIntent::StopWhenIdle);

    let mut fresh = coordinator();
    desired.restore(&mut fresh, 5.0).expect("nothing to start");

    assert_eq!(fresh.running_source(), None);
}

#[test]
fn a_client_with_no_chosen_display_gets_the_primary_on_a_fresh_coordinator() {
    let mut desired = VideoDesired::default();
    desired.note(&VideoIntent::Attach("phone".to_owned()));

    let mut fresh = coordinator();
    desired.restore(&mut fresh, 5.0).expect("the primary starts");

    assert_eq!(fresh.running_source(), Some(&source(1)));
}

#[test]
fn a_coordinator_that_replaces_an_abandoned_pass_tells_the_clients_at_once_and_rebuilds_later() {
    let mut desired = VideoDesired::default();
    desired.note(&VideoIntent::Attach("phone".to_owned()));
    let mut fresh = coordinator();
    desired.restore(&mut fresh, 10.0).expect("the primary starts");
    assert_eq!(fresh.capture_condition(), None);

    fresh.after_abandoned_pass(10.0);

    assert_eq!(fresh.capture_condition(), Some(CaptureCondition::Recovering));
    assert!(fresh.pump(10.2).expect("the backoff is not over").is_empty());
}
