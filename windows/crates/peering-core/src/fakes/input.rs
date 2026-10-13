use peering_wire::command::RemoteCommand;

use crate::ports::input::{InputSink, TransformSnapshot};

/// Records every applied command with the transform it was mapped through, and counts `release_all` calls.
#[derive(Debug, Default)]
pub struct RecordingInput {
    applied: Vec<(RemoteCommand, TransformSnapshot)>,
    release_all_count: usize,
    pointer: Option<(f64, f64)>,
    injected: Option<(f64, f64)>,
    nudges: u64,
}

impl RecordingInput {
    pub fn applied(&self) -> &[(RemoteCommand, TransformSnapshot)] {
        &self.applied
    }

    pub fn release_all_count(&self) -> usize {
        self.release_all_count
    }

    /// Where the real pointer is from now on, as a hand on the mouse would leave it.
    pub fn set_pointer(&mut self, position: Option<(f64, f64)>) {
        self.pointer = position;
    }
}

impl InputSink for RecordingInput {
    fn apply(&mut self, command: &RemoteCommand, transform: &TransformSnapshot) {
        self.applied.push((command.clone(), *transform));
        if let RemoteCommand::MouseMove { .. } | RemoteCommand::JoystickMove { .. } = command {
            self.injected = self.pointer;
        }
        if let RemoteCommand::JoystickMove { .. } = command {
            self.nudges += 1;
        }
    }

    fn release_all(&mut self) {
        self.release_all_count += 1;
    }

    fn pointer_position(&self) -> Option<(f64, f64)> {
        self.pointer
    }

    fn last_injected_position(&self) -> Option<(f64, f64)> {
        self.injected
    }

    fn joystick_nudges(&self) -> u64 {
        self.nudges
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use peering_wire::source::NormalizedPoint;

    fn transform() -> TransformSnapshot {
        TransformSnapshot {
            origin_x: 0,
            origin_y: 0,
            pixel_width: 1512,
            pixel_height: 982,
            scale: 2.0,
        }
    }

    #[test]
    fn applied_commands_are_kept_in_order_with_their_transform() {
        let mut input = RecordingInput::default();
        let first = RemoteCommand::MouseMove { to: NormalizedPoint { x: 0.25, y: 0.5 } };
        input.apply(&first, &transform());
        input.apply(&RemoteCommand::MouseUp { button: peering_wire::command::MouseButton::Left }, &transform());
        assert_eq!(input.applied().len(), 2);
        assert_eq!(input.applied()[0], (first, transform()));
    }

    #[test]
    fn release_all_is_counted() {
        let mut input = RecordingInput::default();
        input.release_all();
        input.release_all();
        assert_eq!(input.release_all_count(), 2);
    }
}
