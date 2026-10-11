//! Folder browsing for choosing where an agent chat starts. Mirrors `apple/MacCastHost/Agent/Sessions/AgentDirectoryBrowser.swift`.

mod path;
#[cfg(test)]
mod tests;

use peering_wire::agent::AgentEvent;
use serde_json::{json, Value};

use path::{virtual_of, InvalidPath, VirtualPath};

pub const MAXIMUM_ENTRIES: usize = 2_000;
const NOT_A_FOLDER: &str = "That is not a folder this PC can open.";

/// One item a folder holds, as the filesystem reports it.
///
/// `modified` is seconds since 2001-01-01, a Swift `Date`. A symbolic link to a folder has `is_directory` set.
#[derive(Debug, Clone, PartialEq)]
pub struct ListedEntry {
    pub name: String,
    pub is_directory: bool,
    pub is_symlink: bool,
    pub modified: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ListFailure {
    NotFound,
    NotADirectory,
    AccessDenied,
    Other(String),
}

/// The filesystem as the browser needs it: native Windows paths in, entries out.
pub trait DirectoryLister {
    fn list(&self, native_path: &str) -> Result<Vec<ListedEntry>, ListFailure>;
    /// Drive roots as bare drive letters with a colon, such as `C:`.
    fn roots(&self) -> Vec<String>;
}

pub struct AgentBrowser<L: DirectoryLister> {
    lister: L,
    /// The folder a browse starts at when the request names none, as a Windows path.
    profile_directory: String,
}

impl<L: DirectoryLister> AgentBrowser<L> {
    pub fn new(lister: L, profile_directory: impl Into<String>) -> Self {
        Self {
            lister,
            profile_directory: profile_directory.into(),
        }
    }

    /// Answers a `browse` request with the folders in the requested folder. Files are not listed.
    pub fn browse(&self, requested: Option<&str>) -> AgentEvent {
        let requested = requested.map_or_else(|| virtual_of(&self.profile_directory), str::to_owned);
        match path::parse(&requested) {
            Err(InvalidPath) => failure(&requested, NOT_A_FOLDER.to_owned()),
            Ok(VirtualPath::Drives) => {
                let mut roots = self.lister.roots();
                roots.sort_by_key(|root| root.to_lowercase());
                directory("/", roots.iter().map(|root| drive_json(root)).collect())
            }
            Ok(VirtualPath::Native(native)) => match self.lister.list(&native) {
                Ok(listed) => directory(&virtual_of(&native), folder_json(listed)),
                Err(reason) => failure(&requested, message(reason)),
            },
        }
    }
}

/// The folders only, folders first by name without regard to case, so every client shows the same order.
fn folder_json(mut listed: Vec<ListedEntry>) -> Vec<Value> {
    listed.retain(|entry| entry.is_directory);
    listed.sort_by_key(|entry| entry.name.to_lowercase());
    listed.iter().map(entry_json).collect()
}

fn directory(path: &str, mut entries: Vec<Value>) -> AgentEvent {
    let truncated = entries.len() > MAXIMUM_ENTRIES;
    entries.truncate(MAXIMUM_ENTRIES);
    AgentEvent::Directory {
        path: path.to_owned(),
        entries,
        truncated,
    }
}

fn failure(path: &str, message: String) -> AgentEvent {
    AgentEvent::BrowseFailure {
        path: path.to_owned(),
        message,
    }
}

fn entry_json(entry: &ListedEntry) -> Value {
    let permissions = if entry.is_symlink { "lrwxrwxrwx" } else { "drwxr-xr-x" };
    let mut json = json!({
        "name": entry.name,
        "isDirectory": true,
        "isSymlink": entry.is_symlink,
        "size": 0,
        "permissions": permissions,
    });
    if let Some(modified) = entry.modified {
        json["modified"] = json!(modified);
    }
    json
}

fn drive_json(root: &str) -> Value {
    json!({
        "name": root,
        "isDirectory": true,
        "isSymlink": false,
        "size": 0,
        "permissions": "drwxr-xr-x",
    })
}

fn message(reason: ListFailure) -> String {
    match reason {
        ListFailure::NotFound => "That is no longer there.".to_owned(),
        ListFailure::NotADirectory => "Part of that path is not a folder.".to_owned(),
        ListFailure::AccessDenied => "Windows did not let Peering read this.".to_owned(),
        ListFailure::Other(text) => text,
    }
}
