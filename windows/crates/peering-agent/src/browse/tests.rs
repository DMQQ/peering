use std::collections::BTreeMap;

use peering_wire::agent::AgentEvent;

use super::*;

const PROFILE: &str = "C:\\Users\\me";

#[derive(Default)]
struct FakeLister {
    folders: BTreeMap<String, Vec<ListedEntry>>,
    roots: Vec<String>,
    denied: Option<String>,
}

impl FakeLister {
    fn with_folder(mut self, path: &str, entries: Vec<ListedEntry>) -> Self {
        self.folders.insert(path.trim_end_matches('\\').to_owned(), entries);
        self
    }
}

impl DirectoryLister for FakeLister {
    fn list(&self, native_path: &str) -> Result<Vec<ListedEntry>, ListFailure> {
        let key = native_path.trim_end_matches('\\');
        if self.denied.as_deref() == Some(key) {
            return Err(ListFailure::AccessDenied);
        }
        self.folders.get(key).cloned().ok_or(ListFailure::NotFound)
    }

    fn roots(&self) -> Vec<String> {
        self.roots.clone()
    }
}

fn folder(name: &str, modified: Option<f64>) -> ListedEntry {
    ListedEntry {
        name: name.to_owned(),
        is_directory: true,
        is_symlink: false,
        modified,
    }
}

fn file(name: &str) -> ListedEntry {
    ListedEntry {
        name: name.to_owned(),
        is_directory: false,
        is_symlink: false,
        modified: None,
    }
}

fn names(event: &AgentEvent) -> Vec<String> {
    match event {
        AgentEvent::Directory { entries, .. } => entries
            .iter()
            .map(|entry| entry["name"].as_str().expect("name is text").to_owned())
            .collect(),
        other => panic!("expected a directory, got {other:?}"),
    }
}

fn home_lister() -> FakeLister {
    FakeLister {
        roots: vec!["D:".to_owned(), "C:".to_owned()],
        ..FakeLister::default()
    }
    .with_folder(
        "C:\\Users\\me",
        vec![file("notes.txt"), folder("Projects", Some(100.0)), folder("alpha", None), folder("Zeta", None)],
    )
    .with_folder("C:\\Users\\me\\Projects", vec![folder("app", None)])
}

#[test]
fn the_root_lists_the_drives_sorted_by_letter() {
    let browser = AgentBrowser::new(home_lister(), PROFILE);
    let event = browser.browse(Some("/"));
    assert_eq!(names(&event), ["C:", "D:"]);
    match event {
        AgentEvent::Directory { path, truncated, .. } => {
            assert_eq!(path, "/");
            assert!(!truncated);
        }
        other => panic!("expected a directory, got {other:?}"),
    }
}

#[test]
fn a_folder_lists_only_its_folders_in_case_blind_order() {
    let browser = AgentBrowser::new(home_lister(), PROFILE);
    let event = browser.browse(Some("/C:/Users/me"));
    assert_eq!(names(&event), ["alpha", "Projects", "Zeta"]);
    let AgentEvent::Directory { path, .. } = event else {
        panic!("expected a directory");
    };
    assert_eq!(path, "/C:/Users/me");
}

#[test]
fn a_request_without_a_path_starts_at_the_profile_folder() {
    let browser = AgentBrowser::new(home_lister(), PROFILE);
    let event = browser.browse(None);
    assert_eq!(names(&event), ["alpha", "Projects", "Zeta"]);
    let AgentEvent::Directory { path, .. } = event else {
        panic!("expected a directory");
    };
    assert_eq!(path, "/C:/Users/me");
}

#[test]
fn a_folder_entry_carries_its_modified_date_only_when_known() {
    let browser = AgentBrowser::new(home_lister(), PROFILE);
    let AgentEvent::Directory { entries, .. } = browser.browse(Some("/C:/Users/me")) else {
        panic!("expected a directory");
    };
    let projects = entries.iter().find(|entry| entry["name"] == "Projects").expect("listed");
    assert_eq!(projects["modified"], 100.0);
    assert_eq!(projects["permissions"], "drwxr-xr-x");
    let alpha = entries.iter().find(|entry| entry["name"] == "alpha").expect("listed");
    assert!(alpha.get("modified").is_none());
}

#[test]
fn a_link_to_a_folder_is_listed_as_a_folder_with_a_link_mode() {
    let lister = FakeLister::default().with_folder(
        "C:\\Work",
        vec![ListedEntry {
            name: "shortcut".to_owned(),
            is_directory: true,
            is_symlink: true,
            modified: None,
        }],
    );
    let AgentEvent::Directory { entries, .. } = AgentBrowser::new(lister, PROFILE).browse(Some("/C:/Work")) else {
        panic!("expected a directory");
    };
    assert_eq!(entries[0]["isSymlink"], true);
    assert_eq!(entries[0]["permissions"], "lrwxrwxrwx");
}

#[test]
fn a_relative_path_is_refused_as_not_a_folder() {
    let browser = AgentBrowser::new(home_lister(), PROFILE);
    assert_eq!(
        browser.browse(Some("C:/Users")),
        AgentEvent::BrowseFailure {
            path: "C:/Users".to_owned(),
            message: "That is not a folder this PC can open.".to_owned(),
        }
    );
}

#[test]
fn a_path_that_climbs_out_of_its_drive_is_refused() {
    let browser = AgentBrowser::new(home_lister(), PROFILE);
    let event = browser.browse(Some("/C:/Users/me/../../Windows"));
    assert!(matches!(event, AgentEvent::BrowseFailure { .. }));
}

#[test]
fn a_missing_folder_reports_that_it_is_gone() {
    let event = AgentBrowser::new(home_lister(), PROFILE).browse(Some("/C:/Nope"));
    assert_eq!(
        event,
        AgentEvent::BrowseFailure {
            path: "/C:/Nope".to_owned(),
            message: "That is no longer there.".to_owned(),
        }
    );
}

#[test]
fn a_denied_folder_reports_that_windows_refused() {
    let lister = FakeLister {
        denied: Some("C:\\Locked".to_owned()),
        ..FakeLister::default()
    };
    let event = AgentBrowser::new(lister, PROFILE).browse(Some("/C:/Locked"));
    assert!(matches!(
        event,
        AgentEvent::BrowseFailure { ref message, .. } if message == "Windows did not let Peering read this."
    ));
}

#[test]
fn a_listing_past_the_entry_cap_is_cut_and_marked_truncated() {
    let many: Vec<ListedEntry> = (0..=MAXIMUM_ENTRIES).map(|index| folder(&format!("d{index:05}"), None)).collect();
    let lister = FakeLister::default().with_folder("C:\\Big", many);
    let event = AgentBrowser::new(lister, PROFILE).browse(Some("/C:/Big"));
    match event {
        AgentEvent::Directory { entries, truncated, .. } => {
            assert_eq!(entries.len(), MAXIMUM_ENTRIES);
            assert!(truncated);
        }
        other => panic!("expected a directory, got {other:?}"),
    }
}
