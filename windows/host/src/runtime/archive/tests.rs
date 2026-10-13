use std::path::PathBuf;

use peering_core::files::fake::InMemoryFileSystem;

use super::*;

fn temporary(name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!("peering-archive-{name}-{}", std::process::id()));
    drop(fs::remove_dir_all(&path));
    path
}

fn project() -> InMemoryFileSystem {
    let mut fs = InMemoryFileSystem::default();
    fs.add_file("C:\\Users\\me\\Project\\readme.txt", b"read me", 0.0);
    fs.add_file("C:\\Users\\me\\Project\\src\\main.rs", b"fn main() {}", 0.0);
    fs
}

/// Each test has places of its own, so tests running together do not make each other busy.
fn zip(fs: &InMemoryFileSystem, root: &Path, requested: &str, id: &str) -> TerminalEvent {
    zip_folder(&Places::new(MAXIMUM_AT_ONCE), fs, root, "S", requested, id)
}

fn range(path: &str, offset: i64, total: i64, length: usize) -> TerminalEvent {
    TerminalEvent::FileRange { session_id: "S".to_owned(), path: path.to_owned(), offset, total_bytes: total, data: vec![0; length] }
}

#[test]
fn a_folder_is_zipped_into_its_own_directory_and_announced() {
    let root = temporary("announce");
    let TerminalEvent::ArchiveReady { session_id, folder, archive_path, total_bytes } = zip(&project(), &root, "/C:/Users/me/Project", "one") else {
        panic!("an archive is ready");
    };
    assert_eq!((session_id.as_str(), folder.as_str()), ("S", "/C:/Users/me/Project"));
    assert!(archive_path.ends_with("/one/Project.zip"), "{archive_path}");
    let written = fs::metadata(root.join("one").join("Project.zip")).expect("the zip is on disk");
    assert_eq!(written.len() as i64, total_bytes);
    drop(fs::remove_dir_all(&root));
}

#[test]
fn a_path_that_is_not_a_folder_on_a_drive_is_refused() {
    let root = temporary("refuse");
    for requested in ["/", "relative", "/C:/../x"] {
        let TerminalEvent::TransferFailure { path, message, .. } = zip(&project(), &root, requested, "x") else {
            panic!("a failure for {requested}");
        };
        assert_eq!((path.as_str(), message.as_str()), (requested, NOT_A_PATH));
    }
    assert!(!root.exists(), "nothing was made");
}

#[test]
fn a_file_is_not_a_folder_and_leaves_nothing_behind() {
    let root = temporary("file");
    let TerminalEvent::TransferFailure { message, .. } = zip(&project(), &root, "/C:/Users/me/Project/readme.txt", "f") else {
        panic!("a failure");
    };
    assert_eq!(message, NOT_A_FOLDER);
    assert!(!root.join("f").exists());
    drop(fs::remove_dir_all(&root));
}

#[test]
fn a_zip_is_stale_after_an_hour() {
    assert!(!is_stale(Duration::from_secs(3_600)));
    assert!(is_stale(Duration::from_secs(3_601)));
}

#[cfg(unix)]
#[test]
fn a_zip_made_a_long_time_ago_is_removed_when_the_next_is_made() {
    let root = temporary("stale");
    fs::create_dir_all(root.join("old")).expect("a folder");
    File::open(root.join("old")).expect("the folder opens").set_modified(SystemTime::now() - Duration::from_secs(7_200)).expect("an old time");
    fs::create_dir_all(root.join("recent")).expect("a folder");
    zip(&project(), &root, "/C:/Users/me/Project", "new");
    assert!(!root.join("old").exists());
    assert!(root.join("recent").exists(), "a zip a phone may still be reading stays");
    assert!(root.join("new").exists());
    drop(fs::remove_dir_all(&root));
}

#[test]
fn a_drive_root_has_a_name_to_keep_as_the_top_folder() {
    assert_eq!(top_name("C:\\Users\\me\\Project"), "Project");
    assert_eq!(top_name("C:\\Users\\me\\Project\\"), "Project");
    assert_eq!(top_name("D:\\"), "Drive D");
    assert_eq!(top_name("D:"), "Drive D");
}

#[test]
fn a_zip_asked_for_while_the_places_are_taken_is_told_to_wait() {
    let places = Places::new(0);
    let TerminalEvent::TransferFailure { message, .. } = zip_folder(&places, &project(), &temporary("busy"), "S", "/C:/Users/me/Project", "b") else {
        panic!("a failure");
    };
    assert_eq!(message, BUSY);
}

#[test]
fn only_the_places_for_zips_are_given_out() {
    let places = Places::new(2);
    let first = places.take().expect("a place");
    let second = places.take().expect("another place");
    assert!(places.take().is_none());
    drop(first);
    assert!(places.take().is_some());
    drop(second);
}

#[test]
fn the_last_piece_of_a_zip_deletes_its_folder() {
    let events = [range("/C:/data/archives/one/Project.zip", 65_536, 100_000, 34_464)];
    assert_eq!(finished_directories("C:\\data\\archives", &events), [PathBuf::from("C:\\data\\archives\\one")]);
}

#[test]
fn a_piece_that_is_not_the_last_deletes_nothing() {
    let events = [range("/C:/data/archives/one/Project.zip", 0, 100_000, 32_768)];
    assert!(finished_directories("C:\\data\\archives", &events).is_empty());
}

#[test]
fn the_end_of_any_other_file_is_never_deleted() {
    let events = [range("/C:/Users/me/notes.txt", 0, 5, 5), range("/C:/data/archivesX/one/a.zip", 0, 1, 1)];
    assert!(finished_directories("C:\\data\\archives", &events).is_empty());
}

#[test]
fn the_root_is_matched_without_regard_to_case() {
    let events = [range("/c:/DATA/Archives/one/Project.zip", 0, 3, 3)];
    assert_eq!(finished_directories("C:\\data\\archives\\", &events).len(), 1);
}
