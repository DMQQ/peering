//! Folder browsing for the agent chat's "where should this chat run" picker. The lister reads the same disk as the file
//! browser, and a request runs off the runtime thread with a timeout.

use std::sync::Arc;
use std::time::Duration;

use peering_agent::browse::{AgentBrowser, DirectoryLister, ListFailure, ListedEntry};
use peering_core::files::vfs::{FileSystem, FsError, RawEntry};
use peering_wire::agent::AgentEvent;
use peering_wire::framing::{Frame, MessageKind};
use tokio::task::spawn_local;

use super::outbound::FrameSender;

const BROWSE_TIMEOUT: Duration = Duration::from_secs(10);
const BROWSE_TIMED_OUT: &str = "This PC took too long to read that.";

pub type FolderBrowser = AgentBrowser<DiskFolders>;

/// The folders of the disk, through the file system port the file browser uses.
pub struct DiskFolders(pub Arc<dyn FileSystem + Send + Sync>);

impl DirectoryLister for DiskFolders {
    fn list(&self, native_path: &str) -> Result<Vec<ListedEntry>, ListFailure> {
        self.0.list(native_path).map(|entries| entries.into_iter().map(listed).collect()).map_err(failure)
    }

    fn roots(&self) -> Vec<String> {
        self.0.roots()
    }
}

fn listed(entry: RawEntry) -> ListedEntry {
    ListedEntry { name: entry.name, is_directory: entry.is_directory, is_symlink: entry.is_symlink, modified: entry.modified }
}

fn failure(error: FsError) -> ListFailure {
    match error {
        FsError::NotFound => ListFailure::NotFound,
        FsError::NotADirectory | FsError::NotAFile => ListFailure::NotADirectory,
        FsError::AccessDenied => ListFailure::AccessDenied,
        FsError::Other(text) => ListFailure::Other(text),
    }
}

/// Answers a `browse` request to `outbound` when the disk has read the folder, or with a failure when it takes too long.
pub fn answer(browser: Arc<FolderBrowser>, path: Option<String>, outbound: FrameSender) {
    spawn_local(async move {
        let asked = path.clone();
        let work = tokio::task::spawn_blocking(move || browser.browse(path.as_deref()));
        let event = match tokio::time::timeout(BROWSE_TIMEOUT, work).await {
            Ok(Ok(event)) => event,
            Ok(Err(_)) | Err(_) => AgentEvent::BrowseFailure {
                path: asked.unwrap_or_else(|| "/".to_owned()),
                message: BROWSE_TIMED_OUT.to_owned(),
            },
        };
        // Derived Serialize with string keys only: text from the CLI or the phone is just a string value, which cannot fail.
        let payload = serde_json::to_vec(&event).expect("agent events always serialise");
        // The connection may have closed meanwhile; there is then nobody to tell.
        let _queued = outbound.send(Frame::new(MessageKind::AgentEvent, payload));
    });
}

#[cfg(test)]
mod tests {
    use peering_core::files::fake::InMemoryFileSystem;

    use super::*;

    fn browser() -> FolderBrowser {
        let mut disk = InMemoryFileSystem::default();
        disk.add_folder("C:\\Users", 1.0);
        disk.add_folder("C:\\Users\\me", 1.0);
        disk.add_folder("C:\\Users\\me\\Projects", 2.0);
        disk.add_file("C:\\Users\\me\\notes.txt", b"x", 3.0);
        AgentBrowser::new(DiskFolders(Arc::new(disk)), "C:\\Users\\me")
    }

    #[test]
    fn a_folder_lists_its_subfolders_and_not_its_files() {
        let AgentEvent::Directory { path, entries, .. } = browser().browse(Some("/C:/Users/me")) else {
            panic!("a directory");
        };
        assert_eq!(path, "/C:/Users/me");
        let names: Vec<&str> = entries.iter().filter_map(|entry| entry["name"].as_str()).collect();
        assert_eq!(names, ["Projects"]);
    }

    #[test]
    fn a_missing_folder_is_a_browse_failure_with_the_reason() {
        let AgentEvent::BrowseFailure { message, .. } = browser().browse(Some("/C:/Users/nobody")) else {
            panic!("a failure");
        };
        assert_eq!(message, "That is no longer there.");
    }

    #[test]
    fn a_request_without_a_path_starts_at_the_profile_folder() {
        let AgentEvent::Directory { path, .. } = browser().browse(None) else { panic!("a directory") };
        assert_eq!(path, "/C:/Users/me");
    }
}
