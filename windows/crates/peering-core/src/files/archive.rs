//! Zipping a folder so the phone can download it as one file, as `TerminalSessionManager+Download.swift` does with `ditto`:
//! the archive keeps the folder's own name as its top folder, and is refused once it passes the cap the phone moves.

use std::io::{self, Read, Write};

use super::vfs::{FileSystem, FsError, RawEntry};
use super::zip::{dos_time, is_limit_exceeded, ZipWriter, MAXIMUM_ENTRIES};

/// A larger file, or a folder whose zip comes out larger, is refused rather than filling the phone (`FileDownloadLimits`).
pub const MAXIMUM_ARCHIVE_BYTES: u64 = 512 * 1024 * 1024;
/// Seconds between the Unix epoch and the 2001-01-01 reference date the wire uses.
const REFERENCE_DATE_OFFSET_SECONDS: i64 = 978_307_200;
const READ_PIECE: usize = 256 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ArchiveError {
    NotAFolder,
    /// The zip would be larger than `MAXIMUM_ARCHIVE_BYTES`, or hold more entries than a zip can name.
    TooLarge,
    Failed(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ArchiveSummary {
    pub bytes: u64,
    pub entries: usize,
    /// Files that could not be read and so are not in the zip, as a PC's system folders always have some.
    pub skipped: usize,
}

/// Writes `folder` (a native path) into `out` as a zip whose top folder is `top_name`. Links are not followed, so a loop or a
/// path back out of the folder is never walked.
pub fn write_archive<F: FileSystem, W: Write>(
    fs: &F,
    folder: &str,
    top_name: &str,
    out: W,
    limit: u64,
) -> Result<(ArchiveSummary, W), ArchiveError> {
    let modified = match fs.stat(folder) {
        Ok(stat) if stat.is_directory => stat.modified,
        Ok(_) | Err(FsError::NotADirectory) => return Err(ArchiveError::NotAFolder),
        Err(error) => return Err(ArchiveError::Failed(format!("{error:?}"))),
    };
    let mut zip = ZipWriter::new(out, limit);
    let mut skipped = 0;
    let mut pending = vec![(folder.to_owned(), top_name.to_owned(), modified)];
    while let Some((native, name, modified)) = pending.pop() {
        if zip.entries() >= MAXIMUM_ENTRIES {
            return Err(ArchiveError::TooLarge);
        }
        add_folder(&mut zip, &format!("{name}/"), modified).map_err(map_io)?;
        let Ok(mut children) = fs.list(&native) else {
            skipped += 1;
            continue;
        };
        // Reversed, because folders are taken from the end of the stack and should come out in name order.
        children.sort_by_key(|child| std::cmp::Reverse(child.name.to_lowercase()));
        for child in children.into_iter().filter(|child| !child.is_symlink) {
            let (child_native, child_name) = (format!("{}\\{}", native.trim_end_matches('\\'), child.name), format!("{name}/{}", child.name));
            if child.is_directory {
                pending.push((child_native, child_name, child.modified));
            } else if zip.entries() >= MAXIMUM_ENTRIES {
                return Err(ArchiveError::TooLarge);
            } else if !add_file(&mut zip, fs, &child_native, &child_name, &child).map_err(map_io)? {
                skipped += 1;
            }
        }
    }
    let entries = zip.entries();
    let (out, bytes) = zip.finish().map_err(map_io)?;
    Ok((ArchiveSummary { bytes, entries, skipped }, out))
}

fn add_folder<W: Write>(zip: &mut ZipWriter<W>, name: &str, modified: Option<f64>) -> io::Result<()> {
    zip.add_folder(name, time_of(modified))
}

/// False when the file could not be opened, so it is left out; any other failure ends the archive.
fn add_file<F: FileSystem, W: Write>(zip: &mut ZipWriter<W>, fs: &F, native: &str, name: &str, entry: &RawEntry) -> io::Result<bool> {
    let mut source = Pieces { fs, path: native, offset: 0, failed: false };
    if fs.read(native, 0, 1).is_err() {
        return Ok(false);
    }
    zip.add_file(name, time_of(entry.modified), &mut source)?;
    Ok(true)
}

/// A file read a piece at a time through the `FileSystem`, which has no streaming reader.
struct Pieces<'a, F: FileSystem> {
    fs: &'a F,
    path: &'a str,
    offset: u64,
    failed: bool,
}

impl<F: FileSystem> Read for Pieces<'_, F> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if self.failed {
            return Ok(0);
        }
        let wanted = buffer.len().min(READ_PIECE);
        match self.fs.read(self.path, self.offset, wanted) {
            Ok(bytes) => {
                buffer[..bytes.len()].copy_from_slice(&bytes);
                self.offset += bytes.len() as u64;
                Ok(bytes.len())
            }
            Err(error) => {
                self.failed = true;
                Err(io::Error::other(format!("{error:?}")))
            }
        }
    }
}

fn time_of(modified: Option<f64>) -> (u16, u16) {
    dos_time(modified.map_or(0, |seconds| seconds as i64 + REFERENCE_DATE_OFFSET_SECONDS))
}

fn map_io(error: io::Error) -> ArchiveError {
    if is_limit_exceeded(&error) { ArchiveError::TooLarge } else { ArchiveError::Failed(error.to_string()) }
}

#[cfg(test)]
mod tests;
