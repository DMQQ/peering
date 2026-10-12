//! The file browser's view of the disk, through `std::fs`. Failures map onto the few cases the browser reports.

use std::fs::{self, DirEntry, File, Metadata};
use std::io::{self, Read, Seek, SeekFrom};
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use peering_core::files::vfs::{FileSystem, FsError, RawEntry};

/// Seconds between the Unix epoch and the 2001-01-01 reference date the wire uses.
const REFERENCE_DATE_OFFSET_SECONDS: f64 = 978_307_200.0;

pub struct DiskFileSystem;

impl FileSystem for DiskFileSystem {
    fn list(&self, path: &str) -> Result<Vec<RawEntry>, FsError> {
        let entries = fs::read_dir(path).map_err(map_error)?;
        // An entry that cannot be read is left out, as Explorer leaves out what it cannot show.
        Ok(entries.filter_map(|entry| entry.ok().and_then(|entry| raw_entry(&entry))).collect())
    }

    fn read(&self, path: &str, offset: u64, limit: usize) -> Result<Vec<u8>, FsError> {
        let metadata = fs::metadata(path).map_err(map_error)?;
        if metadata.is_dir() {
            return Err(FsError::NotAFile);
        }
        let mut file = File::open(path).map_err(map_error)?;
        file.seek(SeekFrom::Start(offset)).map_err(map_error)?;
        let mut bytes = Vec::new();
        file.take(limit as u64).read_to_end(&mut bytes).map_err(map_error)?;
        Ok(bytes)
    }

    fn stat(&self, path: &str) -> Result<RawEntry, FsError> {
        let metadata = fs::symlink_metadata(path).map_err(map_error)?;
        let name = Path::new(path).file_name().map_or_else(|| path.to_owned(), |name| name.to_string_lossy().into_owned());
        Ok(entry_from(name, &metadata, metadata.is_symlink()))
    }

    #[cfg(windows)]
    fn roots(&self) -> Vec<String> {
        ('A'..='Z').map(|letter| format!("{letter}:")).filter(|root| Path::new(&format!("{root}\\")).exists()).collect()
    }

    #[cfg(not(windows))]
    fn roots(&self) -> Vec<String> {
        Vec::new()
    }
}

fn raw_entry(entry: &DirEntry) -> Option<RawEntry> {
    let symlink_metadata = entry.metadata().ok()?;
    let is_symlink = entry.file_type().ok()?.is_symlink();
    let metadata = if is_symlink { fs::metadata(entry.path()).unwrap_or(symlink_metadata) } else { symlink_metadata };
    let name = entry.file_name().to_string_lossy().into_owned();
    Some(entry_from(name, &metadata, is_symlink))
}

fn entry_from(name: String, metadata: &Metadata, is_symlink: bool) -> RawEntry {
    RawEntry {
        name,
        is_directory: metadata.is_dir(),
        is_symlink,
        size: i64::try_from(metadata.len()).unwrap_or(i64::MAX),
        modified: metadata.modified().ok().map(wire_seconds),
    }
}

fn wire_seconds(time: SystemTime) -> f64 {
    let unix = time.duration_since(UNIX_EPOCH).unwrap_or(Duration::ZERO).as_secs_f64();
    unix - REFERENCE_DATE_OFFSET_SECONDS
}

fn map_error(error: io::Error) -> FsError {
    match error.kind() {
        io::ErrorKind::NotFound => FsError::NotFound,
        io::ErrorKind::PermissionDenied => FsError::AccessDenied,
        io::ErrorKind::NotADirectory => FsError::NotADirectory,
        _ => FsError::Other(error.to_string()),
    }
}
