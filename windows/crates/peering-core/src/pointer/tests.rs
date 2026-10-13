use super::*;

fn transform() -> TransformSnapshot {
    TransformSnapshot { origin_x: 0, origin_y: 0, pixel_width: 1000, pixel_height: 500, scale: 1.0 }
}

fn view(cursor: (f64, f64), injected: Option<(f64, f64)>, nudges: u64) -> PointerView {
    PointerView { cursor, injected, nudges, transform: transform() }
}

#[test]
fn the_first_look_is_a_baseline_and_reports_nothing() {
    let mut tracker = PointerTracker::default();
    assert_eq!(tracker.look(0.0, &view((100.0, 100.0), None, 0)), None);
}

#[test]
fn a_hand_moving_the_pointer_is_reported_in_the_picture_s_terms() {
    let mut tracker = PointerTracker::default();
    tracker.look(0.0, &view((100.0, 100.0), None, 0));
    let point = tracker.look(0.1, &view((500.0, 250.0), None, 0)).expect("a hand moved it");
    assert_eq!((point.x, point.y), (0.5, 0.5));
}

#[test]
fn a_move_within_two_pixels_is_not_a_hand() {
    let mut tracker = PointerTracker::default();
    tracker.look(0.0, &view((100.0, 100.0), None, 0));
    assert_eq!(tracker.look(0.1, &view((101.0, 101.0), None, 0)), None);
}

#[test]
fn a_move_the_host_made_for_the_phone_is_not_reported_back() {
    let mut tracker = PointerTracker::default();
    tracker.look(0.0, &view((100.0, 100.0), None, 0));
    assert_eq!(tracker.look(0.1, &view((400.0, 200.0), Some((400.5, 200.5)), 0)), None);
}

#[test]
fn a_hand_after_a_phone_move_is_reported() {
    let mut tracker = PointerTracker::default();
    tracker.look(0.0, &view((100.0, 100.0), None, 0));
    tracker.look(0.1, &view((400.0, 200.0), Some((400.0, 200.0)), 0));
    assert!(tracker.look(0.2, &view((700.0, 400.0), Some((400.0, 200.0)), 0)).is_some());
}

#[test]
fn a_joystick_nudge_is_reported_three_tenths_of_a_second_after_the_last_one() {
    let mut tracker = PointerTracker::default();
    tracker.look(0.0, &view((100.0, 100.0), None, 0));
    assert_eq!(tracker.look(1.0, &view((200.0, 100.0), Some((200.0, 100.0)), 1)), None);
    assert_eq!(tracker.look(1.2, &view((300.0, 100.0), Some((300.0, 100.0)), 2)), None, "a later nudge restarts the wait");
    assert_eq!(tracker.look(1.4, &view((300.0, 100.0), Some((300.0, 100.0)), 2)), None);
    let point = tracker.look(1.55, &view((300.0, 100.0), Some((300.0, 100.0)), 2)).expect("it came to rest");
    assert_eq!((point.x, point.y), (0.3, 0.2));
}

#[test]
fn a_settled_nudge_is_reported_once() {
    let mut tracker = PointerTracker::default();
    tracker.look(0.0, &view((100.0, 100.0), None, 0));
    tracker.look(1.0, &view((200.0, 100.0), Some((200.0, 100.0)), 1));
    assert!(tracker.look(1.4, &view((200.0, 100.0), Some((200.0, 100.0)), 1)).is_some());
    assert_eq!(tracker.look(1.5, &view((200.0, 100.0), Some((200.0, 100.0)), 1)), None);
}

#[test]
fn a_point_outside_the_picture_is_held_at_its_edge() {
    let mut tracker = PointerTracker::default();
    tracker.look(0.0, &view((100.0, 100.0), None, 0));
    let point = tracker.look(0.1, &view((5000.0, -40.0), None, 0)).expect("a hand moved it");
    assert_eq!((point.x, point.y), (1.0, 0.0));
}

#[test]
fn after_a_reset_the_next_look_is_a_baseline_again() {
    let mut tracker = PointerTracker::default();
    tracker.look(0.0, &view((100.0, 100.0), None, 0));
    tracker.reset();
    assert_eq!(tracker.look(0.1, &view((800.0, 400.0), None, 0)), None);
}
