//! Zips a folder for a phone to download. The zip is written under the host's data folder, announced with `archiveReady`, and
//! read by the phone in pieces with the ordinary `readRange`, as on the Mac. It is deleted once its last piece is read, and
//! zips left by an earlier run, or by a phone that never finished, are removed when the next one is made.

use std::fs::{self, File};
use std::io::BufWriter;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, SystemTime};

use peering_core::files::archive::{write_archive, ArchiveError, MAXIMUM_ARCHIVE_BYTES};
use peering_core::files::path::{self, VirtualPath};
use peering_core::files::vfs::FileSystem;
use peering_wire::terminal::TerminalEvent;

/// Two zips at a time, as on the Mac: each reads a whole folder.
const MAXIMUM_AT_ONCE: usize = 2;
const STALE_AFTER: Duration = Duration::from_secs(3600);
/// Past this, a folder that is still being zipped has taken too long; the phone is told rather than left to wait.
pub const ZIP_TIMEOUT: Duration = Duration::from_secs(700);

pub(super) const TIMED_OUT: &str = "This PC did not finish zipping that folder in time.";
const BUSY: &str = "This PC is busy zipping other folders. Try again in a moment.";
const NOT_A_PATH: &str = "That is not a path this PC can open.";
const NOT_A_FOLDER: &str = "That is not a folder.";
const NO_ROOM: &str = "This PC could not make room for the zip.";
const COULD_NOT_ZIP: &str = "This PC could not zip that folder.";

static PLACES: Places = Places::new(MAXIMUM_AT_ONCE);

fn too_large() -> String {
    format!("That folder zips to more than this app moves ({} MB).", MAXIMUM_ARCHIVE_BYTES / 1_048_576)
}

/// Zips `requested`, a path as the phone writes it, and returns the event that answers the request.
pub fn archive_folder<F: FileSystem>(fs: &F, root: &Path, session_id: &str, requested: &str, id: &str) -> TerminalEvent {
    zip_folder(&PLACES, fs, root, session_id, requested, id)
}

fn zip_folder<F: FileSystem>(places: &Places, fs: &F, root: &Path, session_id: &str, requested: &str, id: &str) -> TerminalEvent {
    let failure = |message: &str| TerminalEvent::TransferFailure {
        session_id: session_id.to_owned(),
        path: requested.to_owned(),
        message: message.to_owned(),
    };
    let native = match path::parse(requested) {
        Ok(VirtualPath::Native(native)) => native,
        Ok(VirtualPath::Drives) | Err(_) => return failure(NOT_A_PATH),
    };
    let Some(_place) = places.take() else {
        return failure(BUSY);
    };
    remove_stale(root);
    let directory = root.join(id);
    if fs::create_dir_all(&directory).is_err() {
        return failure(NO_ROOM);
    }
    let file = directory.join(format!("{}.zip", top_name(&native)));
    let written = File::create(&file).map_err(|error| ArchiveError::Failed(error.to_string())).and_then(|created| {
        write_archive(fs, &native, &top_name(&native), BufWriter::new(created), MAXIMUM_ARCHIVE_BYTES).map(|(summary, _out)| summary)
    });
    match written {
        Ok(summary) => TerminalEvent::ArchiveReady {
            session_id: session_id.to_owned(),
            folder: path::virtual_of(&native),
            archive_path: path::virtual_of(&file.to_string_lossy()),
            total_bytes: i64::try_from(summary.bytes).unwrap_or(i64::MAX),
        },
        Err(error) => {
            // A partly written zip is of no use to anyone.
            drop(fs::remove_dir_all(&directory));
            failure(&match error {
                ArchiveError::NotAFolder => NOT_A_FOLDER.to_owned(),
                ArchiveError::TooLarge => too_large(),
                ArchiveError::Failed(_) => COULD_NOT_ZIP.to_owned(),
            })
        }
    }
}

/// Deletes a zip once its last piece has gone to the phone. `events` are the answers to a `readRange`.
pub fn forget_if_finished(root: &Path, events: &[TerminalEvent]) {
    for directory in finished_directories(&root.to_string_lossy(), events) {
        // The directory is the zip's own, named by its id; one that is already gone is the outcome asked for.
        drop(fs::remove_dir_all(directory));
    }
}

/// The folders of the zips whose last piece is among `events`, for zips under `root` only: a phone reading the end of
/// any other file must not delete it. Windows paths do not care about case.
fn finished_directories(root: &str, events: &[TerminalEvent]) -> Vec<PathBuf> {
    let inside = format!("{}\\", root.trim_end_matches('\\').to_lowercase());
    events
        .iter()
        .filter_map(|event| {
            let TerminalEvent::FileRange { path: shown, offset, total_bytes, data, .. } = event else {
                return None;
            };
            let reached = offset.saturating_add(i64::try_from(data.len()).unwrap_or(i64::MAX));
            let Ok(VirtualPath::Native(native)) = path::parse(shown) else {
                return None;
            };
            let (directory, _file) = native.rsplit_once('\\')?;
            (reached >= *total_bytes && native.to_lowercase().starts_with(&inside)).then(|| PathBuf::from(directory))
        })
        .collect()
}

/// Removes everything a run before this one left, since no phone can still be reading it.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn remove_all(root: &Path) {
    drop(fs::remove_dir_all(root));
}

fn remove_stale(root: &Path) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.filter_map(Result::ok) {
        let age = entry.metadata().and_then(|metadata| metadata.modified()).ok().and_then(|modified| SystemTime::now().duration_since(modified).ok());
        if age.is_some_and(is_stale) {
            drop(fs::remove_dir_all(entry.path()));
        }
    }
}

fn is_stale(age: Duration) -> bool {
    age > STALE_AFTER
}

/// The folder's own name, or "Drive C" for a drive's root, which has none.
fn top_name(native: &str) -> String {
    let trimmed = native.trim_end_matches('\\');
    match trimmed.rsplit_once('\\') {
        Some((_, name)) if !name.is_empty() => name.to_owned(),
        _ => format!("Drive {}", trimmed.trim_end_matches(':')),
    }
}

/// How many zips are being made, against how many may be.
struct Places {
    running: AtomicUsize,
    most: usize,
}

impl Places {
    const fn new(most: usize) -> Self {
        Self { running: AtomicUsize::new(0), most }
    }

    fn take(&self) -> Option<Place<'_>> {
        if self.running.fetch_add(1, Ordering::AcqRel) >= self.most {
            self.running.fetch_sub(1, Ordering::AcqRel);
            return None;
        }
        Some(Place(self))
    }
}

/// One of the places for a zip being made; given back when dropped.
struct Place<'a>(&'a Places);

impl Drop for Place<'_> {
    fn drop(&mut self) {
        self.0.running.fetch_sub(1, Ordering::AcqRel);
    }
}

#[cfg(test)]
mod tests;
