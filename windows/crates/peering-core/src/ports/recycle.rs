//! The Recycle Bin. A delete from the phone goes here and not to the disk's free space, so it can be undone on the PC.

pub trait Recycle: Send {
    /// Moves the file or folder at `path` to the bin. The error is the sentence for the phone.
    fn recycle(&self, path: &str) -> Result<(), String>;
}

/// For a host that has no Recycle Bin: nothing is deleted.
#[derive(Debug, Default, Clone, Copy)]
pub struct NoRecycleBin;

impl Recycle for NoRecycleBin {
    fn recycle(&self, _path: &str) -> Result<(), String> {
        Err("This host has no Recycle Bin, so nothing was deleted.".to_owned())
    }
}
