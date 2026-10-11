//! The operating system's view of files, as the browse service needs it. Paths here are native Windows paths
//! such as `C:\Users\me`; the wire's POSIX shaped paths are mapped in `path.rs`.

/// One entry as the filesystem reports it, before the browse service shapes it for the wire.
///
/// `modified` is seconds since 2001-01-01 (a Swift `Date`), which is what the wire carries.
#[derive(Debug, Clone, PartialEq)]
pub struct RawEntry {
    pub name: String,
    pub is_directory: bool,
    pub is_symlink: bool,
    pub size: i64,
    pub modified: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FsError {
    NotFound,
    NotADirectory,
    NotAFile,
    AccessDenied,
    Other(String),
}

pub trait FileSystem {
    /// The entries of a folder, in any order. Hidden entries are included.
    fn list(&self, path: &str) -> Result<Vec<RawEntry>, FsError>;
    /// Up to `limit` bytes of a file starting at `offset`; empty past the end.
    fn read(&self, path: &str, offset: u64, limit: usize) -> Result<Vec<u8>, FsError>;
    fn stat(&self, path: &str) -> Result<RawEntry, FsError>;
    /// The drive roots, as bare drive letters with a colon, such as `C:`.
    fn roots(&self) -> Vec<String>;
}
