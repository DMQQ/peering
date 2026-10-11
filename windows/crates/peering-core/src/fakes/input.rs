use peering_wire::command::RemoteCommand;

use crate::ports::input::{InputSink, TransformSnapshot};

/// Records every applied command with the transform it was mapped through, and counts `release_all` calls.
#[derive(Debug, Default)]
pub struct RecordingInput {
    applied: Vec<(RemoteCommand, TransformSnapshot)>,
    release_all_count: usize,
}

impl RecordingInput {
    pub fn applied(&self) -> &[(RemoteCommand, TransformSnapshot)] {
        &self.applied
    }

    pub fn release_all_count(&self) -> usize {
        self.release_all_count
    }
}

impl InputSink for RecordingInput {
    fn apply(&mut self, command: &RemoteCommand, transform: &TransformSnapshot) {
        self.applied.push((command.clone(), *transform));
    }

    fn release_all(&mut self) {
        self.release_all_count += 1;
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
