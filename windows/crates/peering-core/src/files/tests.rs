use peering_wire::files::{RemoteDirectoryEntry, RemoteEntryKind, RemoteFileKind, RemoteFileOperation};
use peering_wire::terminal::{TerminalEvent, TerminalRequest};

use super::browse::{FileBrowser, MAXIMUM_LISTING_ENTRIES};
use super::fake::InMemoryFileSystem;
use super::path::{parse, virtual_of, InvalidPath, VirtualPath};
use super::preview::{MAXIMUM_TEXT_PREVIEW_BYTES, NOT_A_FILE};

const SESSION: &str = "0A1B2C3D-0000-4000-8000-00000000000F";
const HOME: &str = "C:\\Users\\me";

fn fixture() -> InMemoryFileSystem {
    let mut fs = InMemoryFileSystem::default();
    fs.add_folder("C:\\Users\\me\\Projects", 50.0);
    fs.add_file("C:\\Users\\me\\notes.txt", b"hello world", 200.0);
    fs.add_file("C:\\Users\\me\\Setup.exe", b"MZ", 300.0);
    fs.add_file("C:\\Users\\me\\apple.txt", b"lower", 400.0);
    fs.add_file("C:\\Users\\me\\Projects\\main.rs", b"fn main() {}", 500.0);
    fs.add_folder("D:\\Data", 0.0);
    fs
}

fn browser() -> FileBrowser<InMemoryFileSystem> {
    FileBrowser::new(fixture(), HOME)
}

fn answer(browser: &FileBrowser<InMemoryFileSystem>, request: TerminalRequest) -> TerminalEvent {
    browser.answer(&request).expect("the request is a file request")
}

fn list(browser: &FileBrowser<InMemoryFileSystem>, path: Option<&str>) -> TerminalEvent {
    answer(
        browser,
        TerminalRequest::ListDirectory {
            session_id: SESSION.to_owned(),
            path: path.map(str::to_owned),
        },
    )
}

fn read(browser: &FileBrowser<InMemoryFileSystem>, path: &str) -> TerminalEvent {
    answer(
        browser,
        TerminalRequest::ReadFile {
            session_id: SESSION.to_owned(),
            path: path.to_owned(),
        },
    )
}

fn range(browser: &FileBrowser<InMemoryFileSystem>, path: &str, offset: i64) -> TerminalEvent {
    answer(
        browser,
        TerminalRequest::ReadRange {
            session_id: SESSION.to_owned(),
            path: path.to_owned(),
            offset,
        },
    )
}

fn directory(event: TerminalEvent) -> (String, Vec<RemoteDirectoryEntry>, bool) {
    match event {
        TerminalEvent::Directory { path, entries, truncated, .. } => (path, entries, truncated),
        other => panic!("expected a directory, got {other:?}"),
    }
}

fn names(entries: &[RemoteDirectoryEntry]) -> Vec<&str> {
    entries.iter().map(|entry| entry.name.as_str()).collect()
}

fn browse_message(event: TerminalEvent) -> String {
    match event {
        TerminalEvent::BrowseFailure { message, .. } => message,
        other => panic!("expected a browse failure, got {other:?}"),
    }
}

#[test]
fn the_root_lists_the_drives_as_folders() {
    let (path, entries, truncated) = directory(list(&browser(), Some("/")));
    assert_eq!(path, "/");
    assert!(!truncated);
    assert_eq!(names(&entries), ["C:", "D:"]);
    assert!(entries.iter().all(|entry| entry.is_directory && entry.permissions == "drwxr-xr-x"));
}

#[test]
fn a_nested_folder_lists_folders_first_then_files_by_name_without_case() {
    let (path, entries, _) = directory(list(&browser(), Some("/C:/Users/me")));
    assert_eq!(path, "/C:/Users/me");
    assert_eq!(names(&entries), ["Projects", "apple.txt", "notes.txt", "Setup.exe"]);
}

#[test]
fn a_listing_without_a_path_starts_at_the_home_folder() {
    let (path, entries, _) = directory(list(&browser(), None));
    assert_eq!(path, "/C:/Users/me");
    assert_eq!(entries.len(), 4);
}

#[test]
fn permissions_and_modification_dates_are_synthesised_for_each_entry() {
    let (_, entries, _) = directory(list(&browser(), Some("/C:/Users/me")));
    let by_name = |name: &str| entries.iter().find(|entry| entry.name == name).expect("entry is listed").clone();
    assert_eq!(by_name("notes.txt").permissions, "-rw-r--r--");
    assert_eq!(by_name("Setup.exe").permissions, "-rwxr-xr-x");
    assert_eq!(by_name("Projects").permissions, "drwxr-xr-x");
    assert_eq!(by_name("notes.txt").modified, Some(200.0));
    assert_eq!(by_name("notes.txt").size, 11);
}

#[test]
fn a_listing_past_the_entry_cap_is_cut_and_marked_truncated() {
    let mut fs = InMemoryFileSystem::default();
    for index in 0..=MAXIMUM_LISTING_ENTRIES {
        fs.add_file(&format!("C:\\Big\\file{index:05}.txt"), b"", 0.0);
    }
    let (_, entries, truncated) = directory(list(&FileBrowser::new(fs, HOME), Some("/C:/Big")));
    assert_eq!(entries.len(), MAXIMUM_LISTING_ENTRIES);
    assert!(truncated);
}

#[test]
fn a_virtual_path_maps_to_a_windows_path_and_back() {
    assert_eq!(parse("/C:/Users/me"), Ok(VirtualPath::Native("C:\\Users\\me".to_owned())));
    assert_eq!(parse("/C:"), Ok(VirtualPath::Native("C:\\".to_owned())));
    assert_eq!(parse("/"), Ok(VirtualPath::Drives));
    assert_eq!(virtual_of("C:\\Users\\me"), "/C:/Users/me");
    assert_eq!(virtual_of("C:\\"), "/C:");
}

#[test]
fn a_relative_path_is_refused() {
    assert_eq!(parse("C:/Users"), Err(InvalidPath));
    assert_eq!(parse("Users/me"), Err(InvalidPath));
    let message = browse_message(list(&browser(), Some("Users")));
    assert_eq!(message, "That is not a path this PC can open.");
}

#[test]
fn a_path_that_climbs_out_of_its_drive_is_refused() {
    assert_eq!(parse("/C:/Users/../Windows"), Err(InvalidPath));
    assert_eq!(parse("/C:/./Users"), Err(InvalidPath));
    assert_eq!(parse("/C:/..\\Windows"), Err(InvalidPath));
    assert_eq!(parse("/C:/Users/a:b"), Err(InvalidPath));
    let message = browse_message(read(&browser(), "/C:/Users/../Windows/win.ini"));
    assert_eq!(message, "That is not a path this PC can open.");
}

#[test]
fn a_missing_folder_reports_that_it_is_gone() {
    assert_eq!(browse_message(list(&browser(), Some("/C:/Nope"))), "That is no longer there.");
}

#[test]
fn a_text_file_is_read_whole_when_it_is_small() {
    let TerminalEvent::FileContents { path, kind, offset, total_bytes, data, is_last, .. } =
        read(&browser(), "/C:/Users/me/notes.txt")
    else {
        panic!("expected file contents");
    };
    assert_eq!(path, "/C:/Users/me/notes.txt");
    assert_eq!(kind, RemoteFileKind::Text);
    assert_eq!((offset, total_bytes, is_last), (0, 11, true));
    assert_eq!(data, b"hello world");
}

#[test]
fn a_long_text_file_is_cut_at_the_cap_without_splitting_a_character() {
    let mut fs = InMemoryFileSystem::default();
    let unit = "aé".repeat(MAXIMUM_TEXT_PREVIEW_BYTES);
    fs.add_file("C:\\Logs\\long.txt", unit.as_bytes(), 0.0);
    let event = answer(
        &FileBrowser::new(fs, HOME),
        TerminalRequest::ReadFile {
            session_id: SESSION.to_owned(),
            path: "/C:/Logs/long.txt".to_owned(),
        },
    );
    let TerminalEvent::FileContents { data, is_last, .. } = event else {
        panic!("expected file contents");
    };
    assert!(data.len() <= MAXIMUM_TEXT_PREVIEW_BYTES);
    assert!(std::str::from_utf8(&data).is_ok());
    assert!(!is_last);
}

#[test]
fn a_binary_file_with_no_known_picture_type_is_refused() {
    let mut fs = InMemoryFileSystem::default();
    fs.add_file("C:\\Bin\\blob.dat", &[0x00, 0x01, 0x02], 0.0);
    let event = answer(
        &FileBrowser::new(fs, HOME),
        TerminalRequest::ReadFile {
            session_id: SESSION.to_owned(),
            path: "/C:/Bin/blob.dat".to_owned(),
        },
    );
    assert_eq!(
        browse_message(event),
        "That file is not text or a picture, so there is nothing to show here."
    );
}

#[test]
fn a_picture_is_sent_with_its_picture_kind() {
    let mut fs = InMemoryFileSystem::default();
    fs.add_file("C:\\Pics\\logo.PNG", &[0x89, 0x50, 0x4e, 0x47], 0.0);
    let event = answer(
        &FileBrowser::new(fs, HOME),
        TerminalRequest::ReadFile {
            session_id: SESSION.to_owned(),
            path: "/C:/Pics/logo.PNG".to_owned(),
        },
    );
    let TerminalEvent::FileContents { kind, data, .. } = event else {
        panic!("expected file contents");
    };
    assert_eq!(kind, RemoteFileKind::Image);
    assert_eq!(data, [0x89, 0x50, 0x4e, 0x47]);
}

#[test]
fn reading_a_folder_as_a_file_says_it_is_not_a_file() {
    assert_eq!(browse_message(read(&browser(), "/C:/Users/me/Projects")), NOT_A_FILE);
}

#[test]
fn reading_a_missing_file_reports_that_it_is_gone() {
    assert_eq!(browse_message(read(&browser(), "/C:/Users/me/gone.txt")), "That is no longer there.");
}

#[test]
fn a_denied_folder_says_windows_refused_the_read() {
    let mut fs = fixture();
    fs.deny("C:\\Users\\me\\Projects");
    let message = browse_message(list(&FileBrowser::new(fs, HOME), Some("/C:/Users/me/Projects")));
    assert_eq!(message, "Windows did not let Peering read this.");
}

#[test]
fn a_range_read_returns_the_bytes_from_the_offset() {
    let TerminalEvent::FileRange { path, offset, total_bytes, data, .. } =
        range(&browser(), "/C:/Users/me/notes.txt", 6)
    else {
        panic!("expected a file range");
    };
    assert_eq!(path, "/C:/Users/me/notes.txt");
    assert_eq!((offset, total_bytes), (6, 11));
    assert_eq!(data, b"world");
}

#[test]
fn a_range_past_the_end_is_empty_rather_than_an_error() {
    let TerminalEvent::FileRange { data, total_bytes, .. } = range(&browser(), "/C:/Users/me/notes.txt", 999) else {
        panic!("expected a file range");
    };
    assert_eq!(total_bytes, 11);
    assert!(data.is_empty());
}

#[test]
fn a_negative_range_offset_is_a_transfer_failure() {
    let event = range(&browser(), "/C:/Users/me/notes.txt", -1);
    assert!(matches!(event, TerminalEvent::TransferFailure { .. }));
}

#[test]
fn a_range_of_a_missing_file_is_a_transfer_failure_with_the_reason() {
    let TerminalEvent::TransferFailure { message, .. } = range(&browser(), "/C:/gone.bin", 0) else {
        panic!("expected a transfer failure");
    };
    assert_eq!(message, "That is no longer there.");
}

#[test]
fn archiving_a_folder_is_answered_as_not_supported_yet() {
    let event = answer(
        &browser(),
        TerminalRequest::ArchiveFolder {
            session_id: SESSION.to_owned(),
            path: "/C:/Users/me/Projects".to_owned(),
        },
    );
    let TerminalEvent::TransferFailure { path, message, .. } = event else {
        panic!("expected a transfer failure");
    };
    assert_eq!(path, "/C:/Users/me/Projects");
    assert!(message.contains("yet"));
}

#[test]
fn requests_for_other_features_are_not_answered_here() {
    let request = TerminalRequest::List {};
    assert!(browser().answer(&request).is_none());
}

#[test]
fn starting_an_upload_is_refused_with_a_write_failure() {
    let event = answer(
        &browser(),
        TerminalRequest::BeginWrite { session_id: SESSION.to_owned(), path: "/C:/Users/me/new.bin".to_owned(), total_bytes: 10 },
    );
    let TerminalEvent::WriteFailure { session_id, path, message } = event else {
        panic!("expected a write failure");
    };
    assert_eq!(session_id, SESSION);
    assert_eq!(path, "/C:/Users/me/new.bin");
    assert!(!message.is_empty());
}

#[test]
fn an_upload_chunk_is_refused_with_a_write_failure() {
    let event = answer(
        &browser(),
        TerminalRequest::WriteChunk {
            session_id: SESSION.to_owned(),
            path: "/C:/Users/me/new.bin".to_owned(),
            data: vec![1, 2, 3],
            is_last: true,
        },
    );
    assert!(matches!(event, TerminalEvent::WriteFailure { .. }));
}

#[test]
fn every_file_change_is_refused_with_the_failure_for_its_own_path() {
    let operations = [
        (RemoteFileOperation::Create { path: "/C:/Users/me/a".to_owned(), kind: RemoteEntryKind::File }, "/C:/Users/me/a"),
        (RemoteFileOperation::Rename { path: "/C:/Users/me/b".to_owned(), to: "c".to_owned() }, "/C:/Users/me/b"),
        (RemoteFileOperation::Delete { path: "/C:/Users/me/d".to_owned() }, "/C:/Users/me/d"),
    ];
    for (operation, expected) in operations {
        let event = answer(&browser(), TerminalRequest::ChangeFile { session_id: SESSION.to_owned(), operation });
        let TerminalEvent::FileOperationFailure { path, message, .. } = event else {
            panic!("expected a file operation failure");
        };
        assert_eq!(path, expected);
        assert!(!message.is_empty());
    }
}

#[test]
fn a_request_that_timed_out_is_answered_with_the_failure_that_fits_it() {
    let list = TerminalRequest::ListDirectory { session_id: "s".to_owned(), path: Some("/C:".to_owned()) };
    let range = TerminalRequest::ReadRange { session_id: "s".to_owned(), path: "/C:/a".to_owned(), offset: 0 };
    assert!(matches!(FileBrowser::<InMemoryFileSystem>::failure(&list, "slow"), Some(TerminalEvent::BrowseFailure { .. })));
    assert!(matches!(FileBrowser::<InMemoryFileSystem>::failure(&range, "slow"), Some(TerminalEvent::TransferFailure { .. })));
}
