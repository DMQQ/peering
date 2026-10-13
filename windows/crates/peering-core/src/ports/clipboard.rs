//! The PC's clipboard. Calls may wait on another program that holds it, so the host never calls this under its state lock.

use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClipboardContent {
    Empty,
    Text(String),
    /// A PNG.
    Image(Vec<u8>),
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ClipboardError {
    #[error("the clipboard is in use by another program")]
    Busy,
    #[error("the clipboard could not be read or written: {0}")]
    Failed(String),
}

pub trait Clipboard: Send + Sync {
    /// What the program that owns the clipboard offered first. A picture is skipped when `allow_image` is false.
    fn read(&self, allow_image: bool) -> Result<ClipboardContent, ClipboardError>;

    /// Replaces the clipboard. `Empty` leaves it as it is.
    fn write(&self, content: &ClipboardContent) -> Result<(), ClipboardError>;
}
