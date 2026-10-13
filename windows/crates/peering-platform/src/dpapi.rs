//! Named secrets as files, each sealed by a `Protector`. Windows seals with DPAPI (`dpapi/sys.rs`); the file rules here
//! are the same on every platform and run under test with a stand-in protector.

use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

use peering_core::ports::secret_store::{SecretStore, StoreError};
use zeroize::Zeroizing;

#[cfg(windows)]
mod acl;
pub mod entropy;
#[cfg(windows)]
mod sys;

#[cfg(windows)]
pub use sys::DpapiSealer;

const DIRECTORY_NAME: &str = "Peering Host";

/// Seals and opens secret bytes. `None` means the operation failed and nothing was written or returned.
pub trait Protector {
    fn protect(&self, plain: &[u8]) -> Option<Vec<u8>>;
    fn unprotect(&self, sealed: &[u8]) -> Option<Opened>;

    /// Called before the first secret is written into `directory`, to limit who can open it.
    fn prepare_directory(&self, _directory: &Path) -> io::Result<()> {
        Ok(())
    }

    /// Called for each file already in `directory` when it is prepared, because limiting a directory does not change
    /// the files made inside it earlier.
    fn prepare_file(&self, _file: &Path) -> io::Result<()> {
        Ok(())
    }
}

/// A secret that was opened. `current` is false when it was sealed the way an earlier version did, so the store seals it
/// again the current way.
pub struct Opened {
    pub plain: Zeroizing<Vec<u8>>,
    pub current: bool,
}

/// One sealed file per secret name inside `directory`. A write goes to a temporary file that is renamed over the
/// target, so a failed write leaves the previous value in place.
pub struct SecretFiles<P: Protector> {
    directory: PathBuf,
    protector: P,
    directory_prepared: AtomicBool,
    /// A name that belongs to something else in the same directory, which this store neither reads, writes nor removes.
    reserved: Option<&'static str>,
}

#[cfg(windows)]
pub type DpapiStore = SecretFiles<entropy::EntropyProtector<DpapiSealer>>;

impl<P: Protector> SecretFiles<P> {
    pub fn new(directory: PathBuf, protector: P) -> Self {
        Self { directory, protector, directory_prepared: AtomicBool::new(false), reserved: None }
    }

    pub fn reserving(mut self, name: &'static str) -> Self {
        self.reserved = Some(name);
        self
    }

    fn refuses(&self, name: &str) -> bool {
        self.reserved == Some(name)
    }

    /// Seals again, the current way, every secret that was sealed an earlier way, and says how many there were. A file that
    /// does not open is left as it is.
    pub fn migrate(&self) -> usize {
        let Ok(entries) = fs::read_dir(&self.directory) else {
            return 0;
        };
        let names: Vec<String> = entries.flatten().filter_map(|entry| entry.file_name().into_string().ok()).collect();
        names.iter().filter(|name| self.reseal(name)).count()
    }

    fn reseal(&self, name: &str) -> bool {
        let Ok(Some(opened)) = self.open(name) else {
            return false;
        };
        !opened.current && self.write(name, &opened.plain)
    }

    fn open(&self, name: &str) -> Result<Option<Opened>, StoreError> {
        if self.refuses(name) {
            return Err(StoreError);
        }
        let path = secret_path(&self.directory, name).ok_or(StoreError)?;
        let sealed = match fs::read(path) {
            Ok(sealed) => sealed,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(StoreError),
        };
        self.protector.unprotect(&sealed).map(Some).ok_or(StoreError)
    }

    /// A directory that could not be restricted holds no secrets: the sealing alone should not be the only protection.
    fn prepare_directory(&self) -> bool {
        if self.directory_prepared.load(Ordering::Acquire) {
            return true;
        }
        if self.protector.prepare_directory(&self.directory).is_err() || !self.prepare_existing_files() {
            return false;
        }
        self.directory_prepared.store(true, Ordering::Release);
        true
    }
}

impl<P: Protector> SecretFiles<P> {
    fn prepare_existing_files(&self) -> bool {
        let Ok(entries) = fs::read_dir(&self.directory) else {
            return false;
        };
        entries.flatten().filter(|entry| entry.path().is_file()).all(|entry| self.protector.prepare_file(&entry.path()).is_ok())
    }
}

/// `%LOCALAPPDATA%\Peering Host`, or None when the variable is unset.
pub fn default_directory() -> Option<PathBuf> {
    std::env::var_os("LOCALAPPDATA").map(|base| PathBuf::from(base).join(DIRECTORY_NAME))
}

/// The file for `name` inside `directory`. Names are limited to ASCII letters, digits, `-` and `_`, so no name can
/// reach a separator, a parent directory or a drive.
pub fn secret_path(directory: &Path, name: &str) -> Option<PathBuf> {
    let well_formed = !name.is_empty()
        && name.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_');
    well_formed.then(|| directory.join(name))
}

impl<P: Protector> SecretStore for SecretFiles<P> {
    fn read(&self, name: &str) -> Result<Option<Vec<u8>>, StoreError> {
        let Some(mut opened) = self.open(name)? else {
            return Ok(None);
        };
        if !opened.current {
            // A failed re-seal leaves the old file readable, so it is tried again on the next read.
            let _resealed = self.write(name, &opened.plain);
        }
        Ok(Some(std::mem::take(&mut *opened.plain)))
    }

    fn write(&self, name: &str, value: &[u8]) -> bool {
        let Some(path) = secret_path(&self.directory, name).filter(|_| !self.refuses(name)) else {
            return false;
        };
        let Some(sealed) = self.protector.protect(value) else {
            return false;
        };
        fs::create_dir_all(&self.directory).is_ok() && self.prepare_directory() && write_atomically(&path, &sealed).is_ok()
    }

    fn remove(&self, name: &str) -> bool {
        if self.refuses(name) {
            return false;
        }
        let Some(path) = secret_path(&self.directory, name) else {
            return true;
        };
        match fs::remove_file(path) {
            Ok(()) => true,
            Err(error) => error.kind() == io::ErrorKind::NotFound,
        }
    }
}

fn write_atomically(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let temporary = path.with_extension("tmp");
    let result = write_and_rename(&temporary, path, bytes);
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn write_and_rename(temporary: &Path, target: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut file = File::create(temporary)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    drop(file);
    fs::rename(temporary, target)
}

#[cfg(test)]
mod tests;
