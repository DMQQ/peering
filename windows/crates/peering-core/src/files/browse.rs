//! Answers the terminal requests that read folders and files. Mirrors `TerminalSessionManager+FileBrowsing.swift`,
//! `TerminalSessionManager+Download.swift` and `DirectoryListing.swift`.

use peering_wire::files::RemoteDirectoryEntry;
use peering_wire::terminal::{TerminalEvent, TerminalRequest};

use super::path::{self, VirtualPath};
use super::preview::{self, NOT_A_FILE, RANGE_CHUNK_BYTES};
use super::vfs::{FileSystem, RawEntry};

pub const MAXIMUM_LISTING_ENTRIES: usize = 2_000;
const NOT_A_PATH: &str = "That is not a path this PC can open.";
const ARCHIVE_UNSUPPORTED: &str = "Folders cannot be downloaded from this PC yet.";

pub struct FileBrowser<F: FileSystem> {
    fs: F,
    /// The folder a listing starts at when the request names none, as a Windows path.
    home_directory: String,
}

impl<F: FileSystem> FileBrowser<F> {
    pub fn new(fs: F, home_directory: impl Into<String>) -> Self {
        Self {
            fs,
            home_directory: home_directory.into(),
        }
    }

    /// The event that answers a request this service serves, or `None` for every other request.
    pub fn answer(&self, request: &TerminalRequest) -> Option<TerminalEvent> {
        match request {
            TerminalRequest::ListDirectory { session_id, path } => {
                Some(self.list_directory(session_id, path.as_deref()))
            }
            TerminalRequest::ReadFile { session_id, path } => Some(self.read_file(session_id, path)),
            TerminalRequest::ReadRange { session_id, path, offset } => {
                Some(self.read_range(session_id, path, *offset))
            }
            TerminalRequest::ArchiveFolder { session_id, path } => Some(TerminalEvent::TransferFailure {
                session_id: session_id.clone(),
                path: path.clone(),
                message: ARCHIVE_UNSUPPORTED.to_owned(),
            }),
            _ => None,
        }
    }

    fn list_directory(&self, session_id: &str, requested: Option<&str>) -> TerminalEvent {
        let requested = requested.map_or_else(|| path::virtual_of(&self.home_directory), str::to_owned);
        match path::parse(&requested) {
            Err(_) => browse_failure(session_id, &requested, NOT_A_PATH),
            Ok(VirtualPath::Drives) => TerminalEvent::Directory {
                session_id: session_id.to_owned(),
                path: "/".to_owned(),
                entries: sorted_folders_first(self.fs.roots().iter().map(|root| drive_entry(root)).collect()),
                truncated: false,
            },
            Ok(VirtualPath::Native(native)) => match self.fs.list(&native) {
                Ok(raw) => listing(session_id, &path::virtual_of(&native), raw),
                Err(error) => browse_failure(session_id, &requested, &preview::message(error)),
            },
        }
    }

    fn read_file(&self, session_id: &str, requested: &str) -> TerminalEvent {
        let native = match path::parse(requested) {
            Ok(VirtualPath::Native(native)) => native,
            Ok(VirtualPath::Drives) => return browse_failure(session_id, requested, NOT_A_FILE),
            Err(_) => return browse_failure(session_id, requested, NOT_A_PATH),
        };
        let shown = path::virtual_of(&native);
        let stat = match self.fs.stat(&native) {
            Ok(stat) if stat.is_directory => return browse_failure(session_id, &shown, NOT_A_FILE),
            Ok(stat) => stat,
            Err(error) => return browse_failure(session_id, &shown, &preview::message(error)),
        };
        match preview::preview(&self.fs, &native, &stat.name, size_of(&stat)) {
            Ok(contents) => TerminalEvent::FileContents {
                session_id: session_id.to_owned(),
                path: shown,
                kind: contents.kind,
                offset: 0,
                total_bytes: contents.total_bytes,
                is_last: u64::try_from(contents.data.len()).unwrap_or(u64::MAX) >= size_of_total(contents.total_bytes),
                data: contents.data,
            },
            Err(message) => browse_failure(session_id, &shown, &message),
        }
    }

    fn read_range(&self, session_id: &str, requested: &str, offset: i64) -> TerminalEvent {
        let native = match path::parse(requested) {
            Ok(VirtualPath::Native(native)) if offset >= 0 => native,
            _ => return transfer_failure(session_id, requested, NOT_A_PATH),
        };
        let shown = path::virtual_of(&native);
        let stat = match self.fs.stat(&native) {
            Ok(stat) if stat.is_directory => return transfer_failure(session_id, &shown, NOT_A_FILE),
            Ok(stat) => stat,
            Err(error) => return transfer_failure(session_id, &shown, &preview::message(error)),
        };
        let total = size_of(&stat);
        let start = u64::try_from(offset).unwrap_or(0).min(total);
        match self.fs.read(&native, start, RANGE_CHUNK_BYTES) {
            Ok(data) => TerminalEvent::FileRange {
                session_id: session_id.to_owned(),
                path: shown,
                offset,
                total_bytes: i64::try_from(total).unwrap_or(i64::MAX),
                data,
            },
            Err(error) => transfer_failure(session_id, &shown, &preview::message(error)),
        }
    }
}

fn listing(session_id: &str, path: &str, raw: Vec<RawEntry>) -> TerminalEvent {
    let entries = sorted_folders_first(raw.iter().map(entry).collect());
    let truncated = entries.len() > MAXIMUM_LISTING_ENTRIES;
    TerminalEvent::Directory {
        session_id: session_id.to_owned(),
        path: path.to_owned(),
        entries: entries.into_iter().take(MAXIMUM_LISTING_ENTRIES).collect(),
        truncated,
    }
}

/// Folders first, then by name without regard to case, so every client shows the same order.
fn sorted_folders_first(mut entries: Vec<RemoteDirectoryEntry>) -> Vec<RemoteDirectoryEntry> {
    entries.sort_by(|a, b| {
        b.is_directory
            .cmp(&a.is_directory)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    entries
}

fn entry(raw: &RawEntry) -> RemoteDirectoryEntry {
    RemoteDirectoryEntry {
        name: raw.name.clone(),
        is_directory: raw.is_directory,
        is_symlink: raw.is_symlink,
        size: raw.size,
        permissions: permissions(&raw.name, raw.is_directory, raw.is_symlink).to_owned(),
        modified: raw.modified,
    }
}

fn drive_entry(root: &str) -> RemoteDirectoryEntry {
    RemoteDirectoryEntry {
        name: root.to_owned(),
        is_directory: true,
        is_symlink: false,
        size: 0,
        permissions: permissions(root, true, false).to_owned(),
        modified: None,
    }
}

/// A `ls -l` style mode synthesised from what Windows records: folders, files, and the executable extensions.
fn permissions(name: &str, is_directory: bool, is_symlink: bool) -> &'static str {
    if is_symlink {
        "lrwxrwxrwx"
    } else if is_directory {
        "drwxr-xr-x"
    } else if is_executable(name) {
        "-rwxr-xr-x"
    } else {
        "-rw-r--r--"
    }
}

fn is_executable(name: &str) -> bool {
    name.rsplit_once('.').is_some_and(|(_, extension)| {
        matches!(extension.to_ascii_lowercase().as_str(), "exe" | "bat" | "cmd" | "ps1" | "com")
    })
}

fn size_of(stat: &RawEntry) -> u64 {
    u64::try_from(stat.size).unwrap_or(0)
}

fn size_of_total(total: i64) -> u64 {
    u64::try_from(total).unwrap_or(0)
}

fn browse_failure(session_id: &str, path: &str, message: &str) -> TerminalEvent {
    TerminalEvent::BrowseFailure {
        session_id: session_id.to_owned(),
        path: path.to_owned(),
        message: message.to_owned(),
    }
}

fn transfer_failure(session_id: &str, path: &str, message: &str) -> TerminalEvent {
    TerminalEvent::TransferFailure {
        session_id: session_id.to_owned(),
        path: path.to_owned(),
        message: message.to_owned(),
    }
}
