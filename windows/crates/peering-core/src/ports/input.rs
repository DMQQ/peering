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
}
