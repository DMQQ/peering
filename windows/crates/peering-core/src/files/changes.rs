//! Making, renaming and deleting files and folders for a phone. Mirrors `TerminalSessionManager+FileChanges.swift`. The name
//! rules are the same ones a path from the phone is held to, so a name cannot step out of its folder or open a device.

use peering_wire::files::{RemoteEntryKind, RemoteFileOperation};
use peering_wire::path_segment::is_name;
use peering_wire::terminal::TerminalEvent;

use super::disk::{DiskOps, Existing};
use super::path::{self, VirtualPath};

const NOT_A_CHANGEABLE_PATH: &str = "That is not a path this PC can change.";
const NOT_A_NAME: &str = "That is not a name a file can have.";
const FOLDER_GONE: &str = "That folder is no longer there.";
const NAME_TAKEN: &str = "Something with that name is already there.";
const NOTHING_THERE: &str = "That is no longer there.";
const TOO_MUCH_TO_DELETE: &str = "That is too much of this PC to delete.";
/// `NAME_MAX` for NTFS is 255 UTF-16 units; a name longer than this is refused before the disk is asked.
const MAXIMUM_NAME_UNITS: usize = 255;

/// Carries out one change and says what happened. The path in the answer is the one the phone sent, so it can match the answer
/// to its request; for a rename that is the old path.
pub fn change<D: DiskOps>(disk: &mut D, session_id: &str, operation: &RemoteFileOperation) -> TerminalEvent {
    let wire_path = match operation {
        RemoteFileOperation::Create { path, .. } | RemoteFileOperation::Rename { path, .. } | RemoteFileOperation::Delete { path } => path,
    };
    let outcome = match path::parse(wire_path) {
        Ok(VirtualPath::Native(native)) => perform(disk, &native, operation),
        _ => Err(NOT_A_CHANGEABLE_PATH.to_owned()),
    };
    match outcome {
        Ok(note) => TerminalEvent::FileOperationDone { session_id: session_id.to_owned(), path: wire_path.clone(), note },
        Err(message) => TerminalEvent::FileOperationFailure { session_id: session_id.to_owned(), path: wire_path.clone(), message },
    }
}

fn perform<D: DiskOps>(disk: &mut D, native: &str, operation: &RemoteFileOperation) -> Result<String, String> {
    match operation {
        RemoteFileOperation::Create { kind, .. } => create(disk, native, *kind),
        RemoteFileOperation::Rename { to, .. } => rename(disk, native, to),
        RemoteFileOperation::Delete { .. } => delete(disk, native),
    }
}

fn split(native: &str) -> Option<(&str, &str)> {
    native.rsplit_once('\\').filter(|(folder, name)| !folder.is_empty() && !name.is_empty())
}

fn create<D: DiskOps>(disk: &mut D, native: &str, kind: RemoteEntryKind) -> Result<String, String> {
    let (folder, name) = split(native).ok_or_else(|| NOT_A_CHANGEABLE_PATH.to_owned())?;
    if !is_name(name) || name.encode_utf16().count() > MAXIMUM_NAME_UNITS {
        return Err(NOT_A_NAME.to_owned());
    }
    if disk.existing(folder).map_err(|error| error.0)? != Existing::Folder {
        return Err(FOLDER_GONE.to_owned());
    }
    match kind {
        RemoteEntryKind::Folder => {
            disk.make_folder(native).map_err(|error| error.0)?;
            Ok(format!("created folder {name}"))
        }
        RemoteEntryKind::File => {
            disk.make_file(native).map_err(|error| error.0)?;
            Ok(format!("created file {name}"))
        }
    }
}

fn rename<D: DiskOps>(disk: &mut D, native: &str, to: &str) -> Result<String, String> {
    let (folder, old_name) = split(native).ok_or_else(|| NOT_A_CHANGEABLE_PATH.to_owned())?;
    if !is_name(to) || to.encode_utf16().count() > MAXIMUM_NAME_UNITS {
        return Err(NOT_A_NAME.to_owned());
    }
    let note = format!("renamed {old_name} to {to}");
    if to == old_name {
        return Ok(note);
    }
    let renamed = format!("{folder}\\{to}");
    // A rename onto a name already taken would replace it, which nobody asked for. The same name in other letters is the same
    // file being respelled, so it is let through.
    let respelling = to.eq_ignore_ascii_case(old_name);
    if !respelling && disk.existing(&renamed).map_err(|error| error.0)? != Existing::Nothing {
        return Err(NAME_TAKEN.to_owned());
    }
    disk.rename(native, &renamed).map_err(|error| error.0)?;
    Ok(note)
}

fn delete<D: DiskOps>(disk: &mut D, native: &str) -> Result<String, String> {
    let (_, name) = split(native).ok_or_else(|| NOT_A_CHANGEABLE_PATH.to_owned())?;
    // Guard rails against a bug rather than a user: no row in the browser can name the folder you are standing in, or a drive.
    // A client that has been got at can.
    if disk.protected().iter().any(|protected| contains(native, protected)) {
        return Err(TOO_MUCH_TO_DELETE.to_owned());
    }
    let existing = disk.existing(native).map_err(|error| error.0)?;
    if existing == Existing::Nothing {
        return Err(NOTHING_THERE.to_owned());
    }
    // Counted before the move, because afterwards there is nothing left to walk, and the answer is only used for the sentence.
    let inside = if existing == Existing::Folder { disk.count_inside(native).unwrap_or(1) } else { 1 };
    disk.recycle(native).map_err(|error| error.0)?;
    Ok(if inside <= 1 {
        format!("moved {name} to the Recycle Bin")
    } else {
        format!("moved {name} and {} more to the Recycle Bin", inside - 1)
    })
}

/// Whether `outer` is `inner` or a folder that holds it. Windows paths are compared without regard to case.
fn contains(outer: &str, inner: &str) -> bool {
    let outer = outer.trim_end_matches('\\').to_lowercase();
    let inner = inner.trim_end_matches('\\').to_lowercase();
    inner == outer || inner.starts_with(&format!("{outer}\\"))
}

#[cfg(test)]
mod tests;
