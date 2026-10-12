//! Keys and mouse buttons the client has pressed and not released. A disconnect sends their releases through the
//! sink before the sink's own `release_all`, so nothing stays down on the host.

use std::collections::BTreeSet;

use peering_wire::command::{Modifiers, MouseButton, RemoteCommand};

use crate::ports::input::{InputSink, TransformSnapshot};

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct HeldInput {
    keys: BTreeSet<u16>,
    buttons: Vec<MouseButton>,
}

impl HeldInput {
    pub fn observe(&mut self, command: &RemoteCommand) {
        match command {
            RemoteCommand::KeyDown { key_code, .. } => {
                self.keys.insert(*key_code);
            }
            RemoteCommand::KeyUp { key_code, .. } => {
                self.keys.remove(key_code);
            }
            RemoteCommand::MouseDown { button } => {
                if !self.buttons.contains(button) {
                    self.buttons.push(*button);
                }
            }
            RemoteCommand::MouseUp { button } => self.buttons.retain(|held| held != button),
            _ => {}
        }
    }

    pub fn is_empty(&self) -> bool {
        self.keys.is_empty() && self.buttons.is_empty()
    }

    /// Releases every held key and button through `input`, then calls its `release_all`.
    pub fn release_held(&mut self, transform: &TransformSnapshot, input: &mut dyn InputSink) {
        for key_code in std::mem::take(&mut self.keys) {
            input.apply(&RemoteCommand::KeyUp { key_code, modifiers: Modifiers::NONE }, transform);
        }
        for button in std::mem::take(&mut self.buttons) {
            input.apply(&RemoteCommand::MouseUp { button }, transform);
        }
        input.release_all();
    }
}

/// A client pings once a second, so this much silence from every session means the phone is gone, not that a key is
/// really still down.
pub const HELD_INPUT_TTL_SECONDS: f64 = 5.0;

/// What the host's clients have left held, and when any of them was last heard from. A phone that drops without a word
/// leaves its keys down until the session is reaped, which takes a minute; this lets go of them after a few seconds.
#[derive(Debug, Default)]
pub struct HoldGuard {
    held: HeldInput,
    last_heard: f64,
}

impl HoldGuard {
    /// Any frame from any authorised session proves a phone is still there.
    pub fn heard(&mut self, now: f64) {
        self.last_heard = now;
    }

    /// Wraps `sink` so what a command leaves held is recorded here.
    pub fn track<'a>(&'a mut self, sink: &'a mut dyn InputSink) -> TrackedInput<'a> {
        TrackedInput::new(sink, &mut self.held)
    }

    pub fn has_held(&self) -> bool {
        !self.held.is_empty()
    }

    /// Releases everything held once no session has been heard for `ttl_seconds`. Returns true when it released.
    pub fn release_if_silent(
        &mut self,
        now: f64,
        ttl_seconds: f64,
        transform: &TransformSnapshot,
        input: &mut dyn InputSink,
    ) -> bool {
        if self.held.is_empty() || now - self.last_heard < ttl_seconds {
            return false;
        }
        self.held.release_held(transform, input);
        true
    }
}

/// Forwards every command to the sink and records what it leaves held.
pub struct TrackedInput<'a> {
    sink: &'a mut dyn InputSink,
    held: &'a mut HeldInput,
}

impl<'a> TrackedInput<'a> {
    pub fn new(sink: &'a mut dyn InputSink, held: &'a mut HeldInput) -> Self {
        Self { sink, held }
    }
}

impl InputSink for TrackedInput<'_> {
    fn apply(&mut self, command: &RemoteCommand, transform: &TransformSnapshot) {
        self.held.observe(command);
        self.sink.apply(command, transform);
    }

    fn release_all(&mut self) {
        *self.held = HeldInput::default();
        self.sink.release_all();
    }
}

#[cfg(test)]
mod tests {
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
        guard.heard(10.0);
        guard.track(&mut input).apply(&key_down(0x10), &transform());

        assert!(!guard.release_if_silent(14.9, HELD_INPUT_TTL_SECONDS, &transform(), &mut input));
        assert!(guard.release_if_silent(15.0, HELD_INPUT_TTL_SECONDS, &transform(), &mut input));

        assert_eq!(input.release_all_count(), 1);
        assert!(!guard.has_held());
    }

    #[test]
    fn a_phone_that_keeps_talking_keeps_its_keys() {
        let mut guard = HoldGuard::default();
        let mut input = RecordingInput::default();
        guard.heard(0.0);
        guard.track(&mut input).apply(&key_down(0x10), &transform());
        for second in 1..30 {
            guard.heard(f64::from(second));
            assert!(!guard.release_if_silent(f64::from(second), HELD_INPUT_TTL_SECONDS, &transform(), &mut input));
        }
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
        guard.heard(0.0);
        guard.track(&mut input).apply(&RemoteCommand::MouseDown { button: MouseButton::Left }, &transform());
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
}
