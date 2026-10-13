use peering_wire::command::RemoteCommand;

/// The source rectangle a remote pointer position is mapped through, in the host's coordinates.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TransformSnapshot {
    pub origin_x: i32,
    pub origin_y: i32,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub scale: f64,
}

/// Injects remote input into the host. Every command is applied in order; nothing is coalesced here.
pub trait InputSink {
    fn apply(&mut self, command: &RemoteCommand, transform: &TransformSnapshot);
    /// Releases every key and mouse button still held. Called on disconnect so nothing stays stuck down.
    fn release_all(&mut self);

    /// Where the real pointer is, in desktop pixels. `None` for a sink that cannot tell.
    fn pointer_position(&self) -> Option<(f64, f64)> {
        None
    }

    /// Where this sink last put the pointer on a client's behalf, in desktop pixels.
    fn last_injected_position(&self) -> Option<(f64, f64)> {
        None
    }

    /// How many joystick nudges this sink has applied, so a watcher can tell that one just happened.
    fn joystick_nudges(&self) -> u64 {
        0
    }

    /// How many times a phone has pressed a mouse button, so a watcher can tell that a tap just happened.
    fn button_presses(&self) -> u64 {
        0
    }
}
