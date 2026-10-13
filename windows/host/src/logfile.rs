//! The host's log: a file in the data folder that grows to a size and is then rotated, so a failure in a windowed build, which has
//! no console, leaves a trace to read. `peering-host.log` is the current file; the three before it are `.1`, `.2` and `.3`.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

use peering_core::calendar::iso_utc;

const FILE_NAME: &str = "peering-host.log";
/// A file is closed for the next at this size, so the log as a whole stays under about four times it.
pub const MAXIMUM_FILE_BYTES: u64 = 1024 * 1024;
const OLDER_FILES: u32 = 3;

pub struct LogFile {
    directory: PathBuf,
    file: Option<File>,
    size: u64,
    maximum: u64,
}

impl LogFile {
    /// Opens the log in `directory`, which is made if it is not there. The file is appended to, so a restart continues it.
    pub fn open(directory: &Path) -> io::Result<Self> {
        Self::open_with(directory, MAXIMUM_FILE_BYTES)
    }

    fn open_with(directory: &Path, maximum: u64) -> io::Result<Self> {
        fs::create_dir_all(directory)?;
        let mut log = Self { directory: directory.to_owned(), file: None, size: 0, maximum };
        log.reopen()?;
        Ok(log)
    }

    /// Writes one line, stamped with the time in UTC. A line is never split across two files.
    pub fn write_line(&mut self, unix_seconds: i64, message: &str) -> io::Result<()> {
        let line = format!("{} {}\n", iso_utc(unix_seconds), message.replace(['\r', '\n'], " "));
        if self.size > 0 && self.size + line.len() as u64 > self.maximum {
            self.rotate()?;
        }
        let file = match self.file.as_mut() {
            Some(file) => file,
            None => self.file.insert(Self::append(&self.path())?),
        };
        file.write_all(line.as_bytes())?;
        self.size += line.len() as u64;
        Ok(())
    }

    pub fn directory(&self) -> &Path {
        &self.directory
    }

    fn path(&self) -> PathBuf {
        self.directory.join(FILE_NAME)
    }

    fn numbered(&self, number: u32) -> PathBuf {
        self.directory.join(format!("{FILE_NAME}.{number}"))
    }

    fn append(path: &Path) -> io::Result<File> {
        OpenOptions::new().create(true).append(true).open(path)
    }

    fn reopen(&mut self) -> io::Result<()> {
        let file = Self::append(&self.path())?;
        self.size = file.metadata()?.len();
        self.file = Some(file);
        Ok(())
    }

    /// The current file becomes `.1`, `.1` becomes `.2`, and so on; the oldest goes. A step that fails leaves the log writing
    /// to the file it has, so it grows past its size rather than stops.
    fn rotate(&mut self) -> io::Result<()> {
        self.file = None;
        let shifted = (|| {
            drop(fs::remove_file(self.numbered(OLDER_FILES)));
            for number in (1..OLDER_FILES).rev() {
                if self.numbered(number).exists() {
                    fs::rename(self.numbered(number), self.numbered(number + 1))?;
                }
            }
            fs::rename(self.path(), self.numbered(1))
        })();
        self.reopen()?;
        shifted
    }
}

static CURRENT: Mutex<Option<LogFile>> = Mutex::new(None);

/// Makes `directory` the place `record` writes to, and writes panics there too. Returns the reason when the folder cannot be used;
/// the host then runs without a log file, as it did before there was one.
pub fn install(directory: &Path) -> io::Result<()> {
    let log = LogFile::open(directory)?;
    *CURRENT.lock().unwrap_or_else(PoisonError::into_inner) = Some(log);
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        record_without_waiting(&format!("panic: {info}"));
        previous(info);
    }));
    Ok(())
}

/// Appends a line to the installed log, if there is one. A line that cannot be written is lost: the log is the last place a
/// failure to write could be reported.
pub fn record(message: &str) {
    if let Some(log) = CURRENT.lock().unwrap_or_else(PoisonError::into_inner).as_mut() {
        drop(log.write_line(unix_now(), message));
    }
}

/// As `record`, for a panic: the thread that panicked may be holding the log, and waiting for it would hang the process.
fn record_without_waiting(message: &str) {
    if let Ok(mut current) = CURRENT.try_lock() {
        if let Some(log) = current.as_mut() {
            drop(log.write_line(unix_now(), message));
        }
    }
}

fn unix_now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| i64::try_from(elapsed.as_secs()).unwrap_or(i64::MAX))
}

/// The folder the log is in, for the window's button that opens it.
pub fn directory() -> Option<PathBuf> {
    CURRENT.lock().unwrap_or_else(PoisonError::into_inner).as_ref().map(|log| log.directory().to_owned())
}

#[cfg(test)]
mod tests;
