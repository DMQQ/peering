use super::*;
use crate::fakes::input::RecordingInput;
use peering_wire::source::NormalizedPoint;

fn transform() -> TransformSnapshot {
    TransformSnapshot { origin_x: 10, origin_y: 20, pixel_width: 1512, pixel_height: 982, scale: 2.0 }
}

fn key_down(key_code: u16) -> RemoteCommand {
    RemoteCommand::KeyDown { key_code, modifiers: Modifiers::NONE }
}

#[test]
fn keys_held_by_a_silent_phone_are_released_after_the_ttl() {
    let mut guard = HoldGuard::default();
    let mut input = RecordingInput::default();
    guard.heard(1, 10.0);
    guard.track(1, &mut input).apply(&key_down(0x10), &transform());

    assert!(!guard.release_if_silent(14.9, HELD_INPUT_TTL_SECONDS, &transform(), &mut input));
    assert!(guard.release_if_silent(15.0, HELD_INPUT_TTL_SECONDS, &transform(), &mut input));

    assert_eq!(input.release_all_count(), 1);
    assert!(!guard.has_held());
}

#[test]
fn a_phone_that_keeps_talking_keeps_its_keys() {
    let mut guard = HoldGuard::default();
    let mut input = RecordingInput::default();
    guard.heard(1, 0.0);
    guard.track(1, &mut input).apply(&key_down(0x10), &transform());
    for second in 1..30 {
        guard.heard(1, f64::from(second));
        assert!(!guard.release_if_silent(f64::from(second), HELD_INPUT_TTL_SECONDS, &transform(), &mut input));
    }
    assert!(guard.has_held());
}

#[test]
fn a_live_second_phone_does_not_keep_a_dropped_phones_keys_down() {
    let mut guard = HoldGuard::default();
    let mut input = RecordingInput::default();
    guard.heard(1, 0.0);
    guard.heard(2, 0.0);
    guard.track(1, &mut input).apply(&key_down(0x10), &transform());
    guard.track(2, &mut input).apply(&key_down(0x20), &transform());
    for second in 1..=6 {
        guard.heard(2, f64::from(second));
    }

    assert!(guard.release_if_silent(6.0, HELD_INPUT_TTL_SECONDS, &transform(), &mut input));

    let released = RemoteCommand::KeyUp { key_code: 0x10, modifiers: Modifiers::NONE };
    assert!(input.applied().contains(&(released, transform())), "the dropped phone's key came up");
    let kept = RemoteCommand::KeyUp { key_code: 0x20, modifiers: Modifiers::NONE };
    assert!(!input.applied().contains(&(kept, transform())), "the live phone keeps its key");
    assert_eq!(input.release_all_count(), 0, "the sink is not blanket-released while a phone still holds a key");
    assert!(guard.has_held());
}

#[test]
fn nothing_is_released_when_nothing_is_held() {
    let mut guard = HoldGuard::default();
    let mut input = RecordingInput::default();
    assert!(!guard.release_if_silent(1000.0, HELD_INPUT_TTL_SECONDS, &transform(), &mut input));
    assert_eq!(input.release_all_count(), 0);
}

#[test]
fn a_mouse_button_held_by_a_silent_phone_is_released_too() {
    let mut guard = HoldGuard::default();
    let mut input = RecordingInput::default();
    guard.heard(1, 0.0);
    guard.track(1, &mut input).apply(&RemoteCommand::MouseDown { button: MouseButton::Left }, &transform());
    assert!(guard.release_if_silent(6.0, HELD_INPUT_TTL_SECONDS, &transform(), &mut input));
    assert!(input.applied().contains(&(RemoteCommand::MouseUp { button: MouseButton::Left }, transform())));
}

#[test]
fn a_key_released_before_the_disconnect_is_not_released_again() {
    let mut held = HeldInput::default();
    held.observe(&key_down(0x10));
    held.observe(&RemoteCommand::KeyUp { key_code: 0x10, modifiers: Modifiers::NONE });
    let mut input = RecordingInput::default();

    held.release_held(&transform(), &mut input);

    assert!(input.applied().is_empty());
    assert_eq!(input.release_all_count(), 1);
}

#[test]
fn a_key_left_down_is_released_with_the_transform_before_release_all() {
    let mut held = HeldInput::default();
    held.observe(&key_down(0x10));
    let mut input = RecordingInput::default();

    held.release_held(&transform(), &mut input);

    assert_eq!(
        input.applied(),
        &[(RemoteCommand::KeyUp { key_code: 0x10, modifiers: Modifiers::NONE }, transform())]
    );
    assert_eq!(input.release_all_count(), 1);
}

#[test]
fn a_repeated_key_down_is_released_once() {
    let mut held = HeldInput::default();
    held.observe(&key_down(0x10));
    held.observe(&key_down(0x10));
    let mut input = RecordingInput::default();

    held.release_held(&transform(), &mut input);

    assert_eq!(input.applied().len(), 1);
}

#[test]
fn a_mouse_button_left_down_is_released() {
    let mut held = HeldInput::default();
    held.observe(&RemoteCommand::MouseDown { button: MouseButton::Right });
    let mut input = RecordingInput::default();

    held.release_held(&transform(), &mut input);

    assert_eq!(input.applied(), &[(RemoteCommand::MouseUp { button: MouseButton::Right }, transform())]);
}

#[test]
fn a_released_mouse_button_is_forgotten() {
    let mut held = HeldInput::default();
    held.observe(&RemoteCommand::MouseDown { button: MouseButton::Left });
    held.observe(&RemoteCommand::MouseUp { button: MouseButton::Left });
    let mut input = RecordingInput::default();

    held.release_held(&transform(), &mut input);

    assert!(input.applied().is_empty());
}

#[test]
fn pointer_movement_holds_nothing() {
    let mut held = HeldInput::default();
    held.observe(&RemoteCommand::MouseMove { to: NormalizedPoint { x: 0.5, y: 0.5 } });
    assert_eq!(held, HeldInput::default());
}

#[test]
fn the_tracked_sink_records_what_passes_through_it() {
    let mut held = HeldInput::default();
    let mut input = RecordingInput::default();
    {
        let mut tracked = TrackedInput::new(&mut input, &mut held);
        tracked.apply(&key_down(0x0C), &transform());
    }
    assert_eq!(input.applied().len(), 1);

    held.release_held(&transform(), &mut input);
    assert_eq!(input.applied().len(), 2);
}

#[test]
fn release_all_through_the_tracked_sink_clears_the_record() {
    let mut held = HeldInput::default();
    let mut input = RecordingInput::default();
    {
        let mut tracked = TrackedInput::new(&mut input, &mut held);
        tracked.apply(&key_down(0x0C), &transform());
        tracked.release_all();
    }
    held.release_held(&transform(), &mut input);
    assert_eq!(input.applied().len(), 1);
    assert_eq!(input.release_all_count(), 2);
}
