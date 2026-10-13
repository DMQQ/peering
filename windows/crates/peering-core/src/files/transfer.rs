//! Files a phone sends to the PC: an upload goes to a scratch file beside its destination and is moved over it only when every
//! byte has arrived, so a transfer that stops leaves the destination as it was. Mirrors `TerminalSessionManager+FileTransfer.swift`,
//! `+UploadHousekeeping.swift`, `FileReplacement.swift` and `UploadWritePolicy.swift`.

use std::collections::HashMap;

use peering_wire::terminal::TerminalEvent;

use super::disk::{DiskOps, Existing};
use super::path::{self, VirtualPath};

pub const MAXIMUM_WRITE_BYTES: i64 = 2 * 1024 * 1024 * 1024;
/// How much of a file may travel in one message.
pub const WRITE_CHUNK_BYTES: usize = 32 * 1024;
pub const MAXIMUM_CONCURRENT_TRANSFERS: usize = 8;
/// A transfer that sends nothing for this long is dropped and its scratch file deleted.
pub const IDLE_SECONDS: f64 = 90.0;
/// Bytes accepted from the network and not yet on disk, across all transfers.
pub const MAXIMUM_QUEUED_BYTES: usize = 16 * 1024 * 1024;

const NOT_A_WRITABLE_PATH: &str = "That is not a path this PC can write to.";
const TOO_LARGE: &str = "That file is too large to send to this PC (the limit is 2 GB).";
const BUSY: &str = "This PC is busy with other transfers. Try again in a moment.";
const GONE: &str = "That file is no longer being written. Choose it again.";
const OVERSIZED_PIECE: &str = "That transfer was sent in pieces this PC cannot accept.";
const SENT_TOO_MUCH: &str = "That transfer sent more than it said it would.";
const STOPPED_EARLY: &str = "That transfer stopped before the whole file arrived.";
const IS_A_FOLDER: &str = "That is a folder, so a file cannot be written over it.";
const DROPPED_IDLE: &str = "That transfer stopped sending, so this PC dropped it.";
pub const DISK_BEHIND: &str = "This PC's disk is not keeping up, so that transfer was stopped.";

/// One upload in progress. `owner` is whatever the caller needs to send the answer to the connection that began it.
struct Pending<O> {
    owner: O,
    wire_path: String,
    target: String,
    staging: String,
    expected: u64,
    received: u64,
    started: bool,
    last_activity: f64,
}

/// The uploads in progress, keyed by the terminal or browsing scope and the destination.
pub struct Transfers<D: DiskOps, O: Clone> {
    disk: D,
    pending: HashMap<(String, String), Pending<O>>,
    new_id: Box<dyn FnMut() -> String + Send>,
}

fn key_of(session_id: &str, native: &str) -> (String, String) {
    // Windows paths are not case sensitive, so two spellings of one destination are one transfer.
    (session_id.to_owned(), native.to_lowercase())
}

fn failure(session_id: &str, path: &str, message: &str) -> TerminalEvent {
    TerminalEvent::WriteFailure { session_id: session_id.to_owned(), path: path.to_owned(), message: message.to_owned() }
}

impl<D: DiskOps, O: Clone> Transfers<D, O> {
    pub fn new(disk: D, new_id: Box<dyn FnMut() -> String + Send>) -> Self {
        Self { disk, pending: HashMap::new(), new_id }
    }

    pub fn disk(&mut self) -> &mut D {
        &mut self.disk
    }

    pub fn in_progress(&self) -> usize {
        self.pending.len()
    }

    /// Opens an upload. `None` means it was accepted; otherwise the event that refuses it.
    pub fn begin(&mut self, owner: O, session_id: &str, wire_path: &str, total_bytes: i64, now: f64) -> Option<TerminalEvent> {
        let Ok(VirtualPath::Native(native)) = path::parse(wire_path) else {
            return Some(failure(session_id, wire_path, NOT_A_WRITABLE_PATH));
        };
        let Some((folder, name)) = native.rsplit_once('\\').filter(|(folder, name)| !folder.is_empty() && !name.is_empty()) else {
            return Some(failure(session_id, wire_path, NOT_A_WRITABLE_PATH));
        };
        let expected = match u64::try_from(total_bytes) {
            Ok(bytes) if total_bytes <= MAXIMUM_WRITE_BYTES => bytes,
            _ => return Some(failure(session_id, wire_path, TOO_LARGE)),
        };
        let key = key_of(session_id, &native);
        if !self.pending.contains_key(&key) && self.pending.len() >= MAXIMUM_CONCURRENT_TRANSFERS {
            return Some(failure(session_id, wire_path, BUSY));
        }
        let staging = format!("{folder}\\.{name}.peering-{}.part", (self.new_id)());
        let record = Pending {
            owner,
            wire_path: wire_path.to_owned(),
            target: native.clone(),
            staging,
            expected,
            received: 0,
            started: false,
            last_activity: now,
        };
        // The record it replaces held a scratch file nothing else will ever close.
        if let Some(replaced) = self.pending.insert(key, record) {
            self.disk.discard(&replaced.staging);
        }
        self.disk.remember_staging_folder(folder);
        None
    }

    /// Takes one piece. `None` means it was accepted and the file is not complete; otherwise the event that ends the transfer,
    /// `WroteFile` or `WriteFailure`.
    pub fn write(&mut self, session_id: &str, wire_path: &str, data: &[u8], is_last: bool, now: f64) -> Option<TerminalEvent> {
        let Ok(VirtualPath::Native(native)) = path::parse(wire_path) else {
            return Some(failure(session_id, wire_path, NOT_A_WRITABLE_PATH));
        };
        let key = key_of(session_id, &native);
        if data.len() > WRITE_CHUNK_BYTES {
            return Some(self.abandon(&key, session_id, wire_path, OVERSIZED_PIECE));
        }
        let Some(pending) = self.pending.get_mut(&key) else {
            return Some(failure(session_id, wire_path, GONE));
        };
        let piece = data.len() as u64;
        if pending.received + piece > pending.expected {
            return Some(self.abandon(&key, session_id, wire_path, SENT_TOO_MUCH));
        }
        pending.received += piece;
        pending.last_activity = now;
        if let Err(error) = append(&mut self.disk, pending, data) {
            return Some(self.abandon(&key, session_id, wire_path, &error));
        }
        if !is_last {
            return None;
        }
        if pending.received != pending.expected {
            return Some(self.abandon(&key, session_id, wire_path, STOPPED_EARLY));
        }
        Some(self.finish(&key, session_id))
    }

    fn finish(&mut self, key: &(String, String), session_id: &str) -> TerminalEvent {
        let Some(mut pending) = self.pending.remove(key) else {
            return failure(session_id, "", GONE);
        };
        let wire_path = pending.wire_path.clone();
        if !pending.started {
            // A file of no bytes never had a piece to create its scratch file.
            if let Err(error) = append(&mut self.disk, &mut pending, &[]) {
                self.disk.discard(&pending.staging);
                return failure(session_id, &wire_path, &error);
            }
        }
        // Checked now and not at the start: the destination may have become a folder during the transfer.
        if matches!(self.disk.existing(&pending.target), Ok(Existing::Folder)) {
            self.disk.discard(&pending.staging);
            return failure(session_id, &wire_path, IS_A_FOLDER);
        }
        match self.disk.commit(&pending.staging, &pending.target) {
            Ok(total_bytes) => TerminalEvent::WroteFile {
                session_id: session_id.to_owned(),
                path: wire_path,
                total_bytes: i64::try_from(total_bytes).unwrap_or(i64::MAX),
            },
            Err(error) => {
                self.disk.discard(&pending.staging);
                failure(session_id, &wire_path, &error.0)
            }
        }
    }

    /// Ends a transfer that cannot go on, throws away what it wrote and says why.
    fn abandon(&mut self, key: &(String, String), session_id: &str, wire_path: &str, message: &str) -> TerminalEvent {
        if let Some(pending) = self.pending.remove(key) {
            self.disk.discard(&pending.staging);
        }
        failure(session_id, wire_path, message)
    }

    /// Stops a transfer from outside, such as the sender running out of room to queue its pieces.
    pub fn stop(&mut self, session_id: &str, wire_path: &str, message: &str) -> TerminalEvent {
        let key = match path::parse(wire_path) {
            Ok(VirtualPath::Native(native)) => key_of(session_id, &native),
            _ => return failure(session_id, wire_path, NOT_A_WRITABLE_PATH),
        };
        self.abandon(&key, session_id, wire_path, message)
    }

    /// Drops the transfers that have sent nothing for too long, returning each owner with what to tell it.
    pub fn drop_idle(&mut self, now: f64) -> Vec<(O, TerminalEvent)> {
        let idle: Vec<(String, String)> =
            self.pending.iter().filter(|(_, pending)| now - pending.last_activity >= IDLE_SECONDS).map(|(key, _)| key.clone()).collect();
        idle.into_iter()
            .filter_map(|key| {
                let pending = self.pending.remove(&key)?;
                self.disk.discard(&pending.staging);
                Some((pending.owner, failure(&key.0, &pending.wire_path, DROPPED_IDLE)))
            })
            .collect()
    }
}

/// Appends a piece, creating the scratch file with the first one. The error is the sentence for the phone.
fn append<D: DiskOps, O>(disk: &mut D, pending: &mut Pending<O>, piece: &[u8]) -> Result<(), String> {
    if !pending.started {
        disk.create_staging(&pending.staging).map_err(|error| error.0)?;
        pending.started = true;
    }
    if piece.is_empty() {
        return Ok(());
    }
    disk.append(&pending.staging, piece).map_err(|error| error.0)
}

/// Whether a file name is a scratch file made by an upload: `.name.peering-<UUID>.part`. Anything else in a folder is not ours
/// to delete.
pub fn is_staging_file(name: &str) -> bool {
    let Some(inner) = name.strip_prefix('.').and_then(|rest| rest.strip_suffix(".part")) else {
        return false;
    };
    inner.rsplit_once(".peering-").is_some_and(|(_, id)| is_uuid(id))
}

fn is_uuid(text: &str) -> bool {
    let groups: Vec<&str> = text.split('-').collect();
    let lengths = [8, 4, 4, 4, 12];
    groups.len() == lengths.len()
        && groups.iter().zip(lengths).all(|(group, length)| group.len() == length && group.bytes().all(|byte| byte.is_ascii_hexdigit()))
}

/// Counts bytes accepted from the network and not yet written, so a disk slower than the network cannot grow memory without end.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct QueuedByteBudget {
    queued: usize,
}

impl QueuedByteBudget {
    pub fn reserve(&mut self, bytes: usize) -> bool {
        if self.queued + bytes > MAXIMUM_QUEUED_BYTES {
            return false;
        }
        self.queued += bytes;
        true
    }

    pub fn release(&mut self, bytes: usize) {
        self.queued = self.queued.saturating_sub(bytes);
    }
}

#[cfg(test)]
mod tests;
