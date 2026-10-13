use super::*;
use peering_wire::command::Modifiers;

fn desktop() -> VirtualDesktop {
    VirtualDesktop { left: 0, top: 0, width: 1920, height: 1080 }
}

fn source(origin_x: i32, origin_y: i32, pixel_width: u32, pixel_height: u32) -> TransformSnapshot {
    TransformSnapshot { origin_x, origin_y, pixel_width, pixel_height, scale: 1.0 }
}

fn point(x: f64, y: f64) -> NormalizedPoint {
    NormalizedPoint { x, y }
}

fn move_flags() -> MouseFlags {
    MouseFlags::MOVE | MouseFlags::ABSOLUTE | MouseFlags::VIRTUAL_DESKTOP
}

#[test]
fn the_top_left_of_the_source_maps_to_the_desktop_origin() {
    let spec = move_event(point(0.0, 0.0), &source(0, 0, 1920, 1080), desktop());
    assert_eq!(spec, MouseEventSpec { flags: move_flags(), dx: 0, dy: 0, data: 0 });
}

#[test]
fn the_bottom_right_of_the_source_maps_to_the_last_absolute_unit() {
    let spec = move_event(point(1.0, 1.0), &source(0, 0, 1920, 1080), desktop());
    assert_eq!((spec.dx, spec.dy), (65535, 65535));
}

#[test]
fn a_second_monitor_left_of_the_primary_uses_the_negative_virtual_origin() {
    let virtual_screen = VirtualDesktop { left: -1920, top: 0, width: 3840, height: 1080 };
    let spec = move_event(point(0.0, 0.0), &source(-1920, 0, 1920, 1080), virtual_screen);
    assert_eq!((spec.dx, spec.dy), (0, 0));
    let centre = move_event(point(0.5, 0.5), &source(-1920, 0, 1920, 1080), virtual_screen);
    assert_eq!((centre.dx, centre.dy), (16388, 32798));
}

#[test]
fn an_out_of_range_point_stays_on_the_captured_source() {
    let inside = move_event(point(1.0, 1.0), &source(0, 0, 800, 600), desktop());
    let outside = move_event(point(7.0, 9.0), &source(0, 0, 800, 600), desktop());
    assert_eq!(inside, outside);
}

#[test]
fn each_button_maps_to_its_down_and_up_flags() {
    assert_eq!(button_event(MouseButton::Left, true).flags, MouseFlags::LEFT_DOWN);
    assert_eq!(button_event(MouseButton::Left, false).flags, MouseFlags::LEFT_UP);
    assert_eq!(button_event(MouseButton::Right, true).flags, MouseFlags::RIGHT_DOWN);
    assert_eq!(button_event(MouseButton::Right, false).flags, MouseFlags::RIGHT_UP);
    assert_eq!(button_event(MouseButton::Middle, true).flags, MouseFlags::MIDDLE_DOWN);
    assert_eq!(button_event(MouseButton::Middle, false).flags, MouseFlags::MIDDLE_UP);
}

#[test]
fn one_downward_line_becomes_a_negative_wheel_delta_of_one_notch() {
    let mut wheel = WheelAccumulator::default();
    let events = wheel_events(0.0, 1.0, &mut wheel);
    assert_eq!(events, vec![MouseEventSpec { flags: MouseFlags::WHEEL, dx: 0, dy: 0, data: -120 }]);
}

#[test]
fn one_upward_line_becomes_a_positive_wheel_delta() {
    let mut wheel = WheelAccumulator::default();
    let events = wheel_events(0.0, -1.0, &mut wheel);
    assert_eq!(events[0].data, 120);
}

#[test]
fn horizontal_scroll_uses_the_horizontal_wheel_with_the_negated_sign() {
    let mut wheel = WheelAccumulator::default();
    let events = wheel_events(2.0, 0.0, &mut wheel);
    assert_eq!(events, vec![MouseEventSpec { flags: MouseFlags::HWHEEL, dx: 0, dy: 0, data: -240 }]);
}

#[test]
fn a_slow_scroll_moves_once_its_fractions_add_up_to_a_notch() {
    let mut wheel = WheelAccumulator::default();
    assert!(wheel_events(0.0, 0.25, &mut wheel).is_empty());
    assert!(wheel_events(0.0, 0.25, &mut wheel).is_empty());
    assert!(wheel_events(0.0, 0.25, &mut wheel).is_empty());
    let events = wheel_events(0.0, 0.25, &mut wheel);
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].data, -120);
}

#[test]
fn the_remainder_keeps_the_direction_of_the_pending_motion() {
    let mut wheel = WheelAccumulator::default();
    assert!(wheel_events(0.0, 0.5, &mut wheel).is_empty());
    assert_eq!(wheel_events(0.0, 0.5, &mut wheel)[0].data, -120);
    assert!(wheel_events(0.0, -0.5, &mut wheel).is_empty());
    assert_eq!(wheel_events(0.0, -0.5, &mut wheel)[0].data, 120);
}

#[test]
fn a_fractional_remainder_never_sends_more_than_it_has_gathered() {
    let mut wheel = WheelAccumulator::default();
    let total: i32 = (0..12).flat_map(|_| wheel_events(0.0, 0.25, &mut wheel)).map(|event| event.data).sum();
    assert_eq!(total, -120 * 3);
}

#[test]
fn non_finite_scroll_is_ignored_and_does_not_poison_the_remainder() {
    let mut wheel = WheelAccumulator::default();
    assert!(wheel_events(f64::NAN, f64::INFINITY, &mut wheel).is_empty());
    assert_eq!(wheel_events(0.0, 1.0, &mut wheel)[0].data, -120);
}

#[test]
fn a_mouse_down_is_followed_by_its_up_on_release_all() {
    let mut injector = MouseInjector::default();
    let down = injector.plan(&RemoteCommand::MouseDown { button: MouseButton::Right }, &source(0, 0, 1920, 1080), desktop());
    assert_eq!(down, vec![button_event(MouseButton::Right, true)]);
    assert_eq!(injector.release_events(), vec![button_event(MouseButton::Right, false)]);
    assert!(injector.release_events().is_empty());
}

#[test]
fn a_released_button_is_not_released_again() {
    let mut injector = MouseInjector::default();
    let transform = source(0, 0, 1920, 1080);
    injector.plan(&RemoteCommand::MouseDown { button: MouseButton::Left }, &transform, desktop());
    injector.plan(&RemoteCommand::MouseUp { button: MouseButton::Left }, &transform, desktop());
    assert!(injector.release_events().is_empty());
}

#[test]
fn a_repeated_down_holds_the_button_once() {
    let mut injector = MouseInjector::default();
    let transform = source(0, 0, 1920, 1080);
    injector.plan(&RemoteCommand::MouseDown { button: MouseButton::Middle }, &transform, desktop());
    injector.plan(&RemoteCommand::MouseDown { button: MouseButton::Middle }, &transform, desktop());
    assert_eq!(injector.release_events(), vec![button_event(MouseButton::Middle, false)]);
}

#[test]
fn release_all_clears_a_pending_wheel_remainder() {
    let mut injector = MouseInjector::default();
    let transform = source(0, 0, 1920, 1080);
    injector.plan(&RemoteCommand::Scroll { dx: 0.0, dy: 0.5 }, &transform, desktop());
    injector.release_events();
    let after = injector.plan(&RemoteCommand::Scroll { dx: 0.0, dy: 0.5 }, &transform, desktop());
    assert!(after.is_empty());
}

#[test]
fn key_commands_produce_no_mouse_events() {
    let mut injector = MouseInjector::default();
    let command = RemoteCommand::KeyDown { key_code: 0, modifiers: Modifiers::NONE };
    assert!(injector.plan(&command, &source(0, 0, 1920, 1080), desktop()).is_empty());
}

fn absolute(fraction: f64, width: i32, height: i32) -> (i32, i32) {
    to_absolute_mouse(fraction * f64::from(width), fraction * f64::from(height), 0, 0, width, height)
}

#[test]
fn a_joystick_nudge_moves_the_pointer_by_the_same_fraction_of_the_picture() {
    let mut injector = MouseInjector::default();
    let transform = source(0, 0, 1920, 1080);
    let first = injector.plan_joystick(192.0, 0.0, &transform, desktop(), (960.0, 540.0));
    // Half way plus a tenth of the width.
    assert_eq!(first[0].dx, absolute(0.6, 1920, 1080).0);
    let second = injector.plan_joystick(0.0, 108.0, &transform, desktop(), (1152.0, 540.0));
    assert_eq!((second[0].dx, second[0].dy), (first[0].dx, absolute(0.6, 1080, 1080).0));
}

#[test]
fn a_nudge_under_one_pixel_is_carried_not_dropped() {
    let mut injector = MouseInjector::default();
    let transform = source(0, 0, 1920, 1080);
    let mut real = (960.0, 540.0);
    for _ in 0..4 {
        injector.plan_joystick(0.5, 0.0, &transform, desktop(), real);
        real = (real.0.round(), real.1);
    }
    let last = injector.plan_joystick(0.0, 0.0, &transform, desktop(), real);
    assert!(last[0].dx > absolute(0.5, 1920, 1080).0);
}

#[test]
fn a_hand_moving_the_pointer_restarts_the_joystick_from_there() {
    let mut injector = MouseInjector::default();
    let transform = source(0, 0, 1920, 1080);
    injector.plan_joystick(0.0, 0.0, &transform, desktop(), (960.0, 540.0));
    let after = injector.plan_joystick(0.0, 0.0, &transform, desktop(), (192.0, 540.0));
    assert_eq!(after[0].dx, absolute(0.1, 1920, 1080).0);
}

#[test]
fn a_joystick_stops_at_the_edge_of_the_source() {
    let mut injector = MouseInjector::default();
    let transform = source(0, 0, 1920, 1080);
    let spec = injector.plan_joystick(5000.0, -5000.0, &transform, desktop(), (960.0, 540.0));
    assert_eq!((spec[0].dx, spec[0].dy), (65535, 0));
}

#[test]
fn a_picture_wider_than_the_phone_measures_in_points_moves_half_as_much() {
    let mut injector = MouseInjector::default();
    let transform = source(0, 0, 3840, 2160);
    let spec = injector.plan_joystick(192.0, 0.0, &transform, VirtualDesktop { left: 0, top: 0, width: 3840, height: 2160 }, (1920.0, 1080.0));
    assert_eq!(spec[0].dx, absolute(0.6, 3840, 2160).0);
}

#[test]
fn a_pointer_move_is_remembered_as_where_the_host_put_the_pointer() {
    let mut injector = MouseInjector::default();
    assert_eq!(injector.last_injected(), None);
    injector.plan(&RemoteCommand::MouseMove { to: point(0.5, 0.25) }, &source(0, 0, 1920, 1080), desktop());
    assert_eq!(injector.last_injected(), Some((960.0, 270.0)));
}

#[test]
fn each_joystick_nudge_is_counted_and_remembered() {
    let mut injector = MouseInjector::default();
    injector.plan_joystick(10.0, 0.0, &source(0, 0, 1920, 1080), desktop(), (100.0, 100.0));
    injector.plan_joystick(10.0, 0.0, &source(0, 0, 1920, 1080), desktop(), (110.0, 100.0));
    assert_eq!(injector.joystick_nudges(), 2);
    assert!(injector.last_injected().is_some());
}
