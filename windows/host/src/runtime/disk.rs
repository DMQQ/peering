//! The file writer's disk: `std::fs`, with the failures put into sentences for the phone. The delete goes to the Recycle Bin
//! through the injected `Recycle`.

use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use peering_core::files::disk::{DiskError, DiskOps, Existing};
use peering_core::files::transfer::is_staging_file;
use peering_core::ports::recycle::Recycle;

/// Scratch files are looked for in the folders of the last uploads, no more than this many.
const REMEMBERED_FOLDERS: usize = 50;
const COUNT_LIMIT: usize = 100_000;

pub struct StdDisk {
    open: HashMap<String, File>,
    recycler: Box<dyn Recycle>,
    protected: Vec<String>,
    /// A file listing the folders that have held scratch files, so a crash does not leave them for good.
    staging_list: Option<PathBuf>,
}

impl StdDisk {
    pub fn new(recycler: Box<dyn Recycle>, protected: Vec<String>, staging_list: Option<PathBuf>) -> Self {
        Self { open: HashMap::new(), recycler, protected, staging_list }
    }
}

/// The sentence for a disk error. Windows error numbers are matched where `ErrorKind` has no name for them.
pub fn message_for(error: &io::Error) -> String {
    use io::ErrorKind::{AlreadyExists, NotADirectory, NotFound, PermissionDenied, StorageFull};
    match (error.kind(), error.raw_os_error()) {
        (PermissionDenied, _) => "Peering is not allowed to change that. If it belongs to another user, save it somewhere else.".to_owned(),
        (NotFound, _) => "That folder is no longer there.".to_owned(),
        (AlreadyExists, _) | (_, Some(80 | 183)) => "Something with that name is already there.".to_owned(),
        (StorageFull, _) | (_, Some(39 | 112)) => "There is not enough room on this PC to save that.".to_owned(),
        (_, Some(32 | 33)) => "Another program is using that file.".to_owned(),
        (NotADirectory, _) | (_, Some(267)) => "Part of that path is not a folder.".to_owned(),
        _ => error.to_string(),
    }
}

fn failed(error: &io::Error) -> DiskError {
    DiskError(message_for(error))
}

impl DiskOps for StdDisk {
    fn existing(&self, path: &str) -> Result<Existing, DiskError> {
        match fs::symlink_metadata(path) {
            Ok(metadata) if metadata.is_dir() => Ok(Existing::Folder),
            Ok(_) => Ok(Existing::File),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(Existing::Nothing),
            Err(error) => Err(failed(&error)),
        }
    }

    fn create_staging(&mut self, path: &str) -> Result<(), DiskError> {
        let file = OpenOptions::new().write(true).create_new(true).open(path).map_err(|error| failed(&error))?;
        self.open.insert(path.to_owned(), file);
        Ok(())
    }

    fn append(&mut self, path: &str, bytes: &[u8]) -> Result<(), DiskError> {
        let file = self.open.get_mut(path).ok_or_else(|| DiskError("The file being written was closed.".to_owned()))?;
        file.write_all(bytes).map_err(|error| failed(&error))
    }

    fn commit(&mut self, staging: &str, target: &str) -> Result<u64, DiskError> {
        if let Some(mut file) = self.open.remove(staging) {
            file.flush().and_then(|()| file.sync_all()).map_err(|error| failed(&error))?;
        }
        let written = fs::metadata(staging).map_err(|error| failed(&error))?.len();
        fs::rename(staging, target).map_err(|error| failed(&error))?;
        Ok(written)
    }

    fn discard(&mut self, staging: &str) {
        self.open.remove(staging);
        // A scratch file that is already gone is what was wanted.
        drop(fs::remove_file(staging));
    }

    fn make_folder(&mut self, path: &str) -> Result<(), DiskError> {
        fs::create_dir(path).map_err(|error| failed(&error))
    }

    fn make_file(&mut self, path: &str) -> Result<(), DiskError> {
        OpenOptions::new().write(true).create_new(true).open(path).map(drop).map_err(|error| failed(&error))
    }

    fn rename(&mut self, from: &str, to: &str) -> Result<(), DiskError> {
        fs::rename(from, to).map_err(|error| failed(&error))
    }

    fn recycle(&mut self, path: &str) -> Result<(), DiskError> {
        self.recycler.recycle(path).map_err(DiskError)
    }

    fn count_inside(&self, path: &str) -> Option<usize> {
        let mut count = 1;
        let mut pending = vec![PathBuf::from(path)];
        while let Some(folder) = pending.pop() {
            for entry in fs::read_dir(&folder).ok()?.flatten() {
                count += 1;
                // A link is one thing whatever it points at, so it is not walked into.
                if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
                    pending.push(entry.path());
                }
                if count >= COUNT_LIMIT {
                    return Some(count);
                }
            }
        }
        Some(count)
    }

    fn protected(&self) -> Vec<String> {
        self.protected.clone()
    }

    fn sweep_orphans(&mut self) {
        let Some(list) = &self.staging_list else {
            return;
        };
        let Ok(text) = fs::read_to_string(list) else {
            return;
        };
        // A list that cannot be cleared is read again next time, which only repeats work that is already done.
        drop(fs::remove_file(list));
        for folder in text.lines().filter(|line| !line.is_empty()) {
            let Ok(entries) = fs::read_dir(folder) else {
                continue;
            };
            for entry in entries.flatten() {
                if is_staging_file(&entry.file_name().to_string_lossy()) {
                    // A scratch file somebody has open stays, and is swept at the next start.
                    drop(fs::remove_file(entry.path()));
                }
            }
        }
    }

    fn remember_staging_folder(&mut self, folder: &str) {
        let Some(list) = &self.staging_list else {
            return;
        };
        let mut folders: Vec<String> = fs::read_to_string(list).map(|text| text.lines().map(str::to_owned).collect()).unwrap_or_default();
        if folders.iter().any(|known| known.eq_ignore_ascii_case(folder)) {
            return;
        }
        folders.push(folder.to_owned());
        let keep = folders.len().saturating_sub(REMEMBERED_FOLDERS);
        let text = folders[keep..].join("\n") + "\n";
        // A list that cannot be written only means a crash would leave this folder's scratch file for the person to delete.
        drop(write_whole(list, text.as_bytes()));
    }
}

fn write_whole(path: &Path, bytes: &[u8]) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, bytes)
}

/// The folders no phone may delete, or any folder that holds one: the user's profile and the places Windows and programs live.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn protected_folders(get: &dyn Fn(&str) -> Option<String>) -> Vec<String> {
    ["USERPROFILE", "SystemRoot", "ProgramFiles", "ProgramFiles(x86)", "ProgramData"].iter().filter_map(|name| get(name)).filter(|value| !value.is_empty()).collect()
}

#[cfg(test)]
mod tests;
