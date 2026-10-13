//! What the file writer needs from the disk. Paths are native Windows paths. Every error carries the sentence the phone is
//! shown, so the decisions in `transfer` need no knowledge of how the disk failed.

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiskError(pub String);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Existing {
    Nothing,
    File,
    Folder,
}

pub trait DiskOps {
    /// What is at `path`, without following a link.
    fn existing(&self, path: &str) -> Result<Existing, DiskError>;
    /// Creates an empty scratch file. Fails if one is already there.
    fn create_staging(&mut self, path: &str) -> Result<(), DiskError>;
    fn append(&mut self, path: &str, bytes: &[u8]) -> Result<(), DiskError>;
    /// Moves the finished scratch file over `target` in one step and returns the size the file on disk has.
    fn commit(&mut self, staging: &str, target: &str) -> Result<u64, DiskError>;
    /// Removes a scratch file. Nothing is left to report when it is already gone.
    fn discard(&mut self, staging: &str);
    fn make_folder(&mut self, path: &str) -> Result<(), DiskError>;
    /// Creates an empty file and fails if the name is taken.
    fn make_file(&mut self, path: &str) -> Result<(), DiskError>;
    /// Gives `from` the new full path `to`. Fails if `to` is taken.
    fn rename(&mut self, from: &str, to: &str) -> Result<(), DiskError>;
    /// Moves to the Recycle Bin, so a delete can be undone on the PC.
    fn recycle(&mut self, path: &str) -> Result<(), DiskError>;
    /// How many entries are inside a folder, or `None` when it cannot be walked.
    fn count_inside(&self, path: &str) -> Option<usize>;
    /// Folders that may not be deleted, nor any folder that holds them.
    fn protected(&self) -> Vec<String>;
    /// Kept so scratch files left by a crash are found at the next start.
    fn remember_staging_folder(&mut self, folder: &str);
    /// Removes scratch files an earlier run left in the folders it remembered. Called once, before the first transfer.
    fn sweep_orphans(&mut self) {}
}

/// A disk chosen when the host starts.
impl DiskOps for Box<dyn DiskOps + Send> {
    fn existing(&self, path: &str) -> Result<Existing, DiskError> {
        (**self).existing(path)
    }

    fn create_staging(&mut self, path: &str) -> Result<(), DiskError> {
        (**self).create_staging(path)
    }

    fn append(&mut self, path: &str, bytes: &[u8]) -> Result<(), DiskError> {
        (**self).append(path, bytes)
    }

    fn commit(&mut self, staging: &str, target: &str) -> Result<u64, DiskError> {
        (**self).commit(staging, target)
    }

    fn discard(&mut self, staging: &str) {
        (**self).discard(staging);
    }

    fn make_folder(&mut self, path: &str) -> Result<(), DiskError> {
        (**self).make_folder(path)
    }

    fn make_file(&mut self, path: &str) -> Result<(), DiskError> {
        (**self).make_file(path)
    }

    fn rename(&mut self, from: &str, to: &str) -> Result<(), DiskError> {
        (**self).rename(from, to)
    }

    fn recycle(&mut self, path: &str) -> Result<(), DiskError> {
        (**self).recycle(path)
    }

    fn count_inside(&self, path: &str) -> Option<usize> {
        (**self).count_inside(path)
    }

    fn protected(&self) -> Vec<String> {
        (**self).protected()
    }

    fn remember_staging_folder(&mut self, folder: &str) {
        (**self).remember_staging_folder(folder);
    }

    fn sweep_orphans(&mut self) {
        (**self).sweep_orphans();
    }
}
