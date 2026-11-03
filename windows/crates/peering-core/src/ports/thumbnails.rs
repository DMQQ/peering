//! Pictures of the sources a phone can choose from, for the picker's grid.

use peering_wire::source::CaptureSource;

/// One picture: its size in pixels and the JPEG bytes, small enough for the catalogue to carry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceImage {
    pub width: u32,
    pub height: u32,
    pub jpeg: Vec<u8>,
}

/// Takes the picture of a display or a window as it looks now. Slow, so it is called off the thread that serves phones.
pub trait SourceThumbnails: Send + Sync {
    fn photograph(&self, source: &CaptureSource) -> Option<SourceImage>;
}

/// A host that cannot take pictures. The picker shows its tiles without them.
#[derive(Debug, Default)]
pub struct NoThumbnails;

impl SourceThumbnails for NoThumbnails {
    fn photograph(&self, _source: &CaptureSource) -> Option<SourceImage> {
        None
    }
}
