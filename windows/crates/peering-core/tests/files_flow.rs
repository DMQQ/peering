//! Browsing the PC's files from a phone: drives, folders, previews, ranged reads, and the refusals for paths that
//! are not absolute or that try to leave their drive. Runs over the in-memory filesystem.

mod common;

use peering_core::files::browse::{FileBrowser, MAXIMUM_LISTING_ENTRIES};
use peering_core::files::fake::InMemoryFileSystem;
use peering_wire::files::RemoteFileKind;
use peering_wire::terminal::{TerminalEvent, TerminalRequest};

const SESSION: &str = "terminal-1";
const NOT_A_PATH: &str = "That is not a path this PC can open.";
const NOT_A_FILE: &str = "That is not a file, so there is nothing to show here.";
const MISSING: &str = "That is no longer there.";
const DENIED: &str = "Windows did not let Peering read this.";
const NOT_TEXT_PREFIX: &str = "That file is not text or a picture";

fn pc() -> InMemoryFileSystem {
    let mut fs = InMemoryFileSystem::default();
    fs.add_folder("C:\\Users\\me", 700.0);
    fs.add_folder("C:\\Users\\Public", 700.0);
    fs.add_file("C:\\Users\\readme.txt", b"top level", 700.0);
    fs.add_file("C:\\Users\\me\\notes.txt", b"hello, phone\n", 800.0);
    fs.add_file("C:\\Users\\me\\photo.png", &[0x89, b'P', b'N', b'G'], 800.0);
    fs.add_file("C:\\Users\\me\\blob.bin", &[0x00, 0x01, 0x02, 0xff], 800.0);
    fs.add_file("C:\\Users\\me\\long.log", &vec![b'a'; 200 * 1024], 800.0);
    fs.add_folder("D:\\Backups", 600.0);
    fs
}

fn browser(fs: InMemoryFileSystem) -> FileBrowser<InMemoryFileSystem> {
    FileBrowser::new(fs, "C:\\Users\\me")
}

fn ask(browser: &FileBrowser<InMemoryFileSystem>, request: TerminalRequest) -> TerminalEvent {
    browser.answer(&request).expect("the browser answers file requests")
}

fn list(browser: &FileBrowser<InMemoryFileSystem>, path: Option<&str>) -> TerminalEvent {
    ask(browser, TerminalRequest::ListDirectory { session_id: SESSION.to_owned(), path: path.map(str::to_owned) })
}

fn read(browser: &FileBrowser<InMemoryFileSystem>, path: &str) -> TerminalEvent {
    ask(browser, TerminalRequest::ReadFile { session_id: SESSION.to_owned(), path: path.to_owned() })
}

fn range(browser: &FileBrowser<InMemoryFileSystem>, path: &str, offset: i64) -> TerminalEvent {
    ask(browser, TerminalRequest::ReadRange { session_id: SESSION.to_owned(), path: path.to_owned(), offset })
}

fn names(event: &TerminalEvent) -> Vec<&str> {
    match event {
        TerminalEvent::Directory { entries, .. } => entries.iter().map(|entry| entry.name.as_str()).collect(),
        other => panic!("expected a directory, got {other:?}"),
    }
}

fn failure_message(event: &TerminalEvent) -> &str {
    match event {
        TerminalEvent::BrowseFailure { message, .. } | TerminalEvent::TransferFailure { message, .. } => message,
        other => panic!("expected a failure, got {other:?}"),
    }
}

#[test]
fn the_root_lists_the_drives_as_folders() {
    let browser = browser(pc());

    let event = list(&browser, Some("/"));

    let TerminalEvent::Directory { path, entries, truncated, .. } = &event else {
        panic!("expected a directory, got {event:?}");
    };
    assert_eq!(path, "/");
    assert_eq!(entries.iter().map(|entry| entry.name.as_str()).collect::<Vec<_>>(), ["C:", "D:"]);
    assert!(entries.iter().all(|entry| entry.is_directory));
    assert!(!truncated);
}

#[test]
fn browsing_into_a_folder_lists_its_contents_under_the_virtual_path() {
    let browser = browser(pc());

    let event = list(&browser, Some("/C:/Users"));

    assert!(matches!(&event, TerminalEvent::Directory { path, .. } if path == "/C:/Users"));
    assert_eq!(names(&event), ["me", "Public", "readme.txt"], "folders first, then files");
}

#[test]
fn a_missing_path_starts_at_the_home_folder() {
    let event = list(&browser(pc()), None);
    assert!(matches!(&event, TerminalEvent::Directory { path, .. } if path == "/C:/Users/me"));
}

#[test]
fn files_in_a_folder_sort_by_name_without_regard_to_case() {
    let mut fs = pc();
    fs.add_file("C:\\Users\\me\\Zeta.txt", b"z", 1.0);
    fs.add_file("C:\\Users\\me\\alpha.txt", b"a", 1.0);
    let browser = browser(fs);

    let event = list(&browser, Some("/C:/Users/me"));

    assert_eq!(
        names(&event),
        ["alpha.txt", "blob.bin", "long.log", "notes.txt", "photo.png", "Zeta.txt"]
    );
}

#[test]
fn a_text_file_previews_in_full_when_it_is_small() {
    let browser = browser(pc());

    let event = read(&browser, "/C:/Users/me/notes.txt");

    let TerminalEvent::FileContents { path, kind, offset, total_bytes, data, is_last, .. } = event else {
        panic!("expected file contents, got {event:?}");
    };
    assert_eq!(path, "/C:/Users/me/notes.txt");
    assert_eq!(kind, RemoteFileKind::Text);
    assert_eq!(offset, 0);
    assert_eq!(total_bytes, 13);
    assert_eq!(data, b"hello, phone\n");
    assert!(is_last);
}

#[test]
fn a_picture_is_previewed_by_its_name_as_an_image() {
    let event = read(&browser(pc()), "/C:/Users/me/photo.png");
    assert!(matches!(&event, TerminalEvent::FileContents { kind: RemoteFileKind::Image, .. }));
}

#[test]
fn a_large_text_file_is_cut_at_the_preview_limit_and_marked_as_not_last() {
    let event = read(&browser(pc()), "/C:/Users/me/long.log");

    let TerminalEvent::FileContents { data, total_bytes, is_last, .. } = event else {
        panic!("expected file contents");
    };
    assert_eq!(total_bytes, 200 * 1024);
    assert!(data.len() < 200 * 1024, "the preview stops short of the whole file");
    assert!(!is_last);
}

#[test]
fn a_ranged_read_returns_the_bytes_from_the_offset() {
    let event = range(&browser(pc()), "/C:/Users/me/notes.txt", 7);

    let TerminalEvent::FileRange { offset, total_bytes, data, .. } = event else {
        panic!("expected a range, got {event:?}");
    };
    assert_eq!(offset, 7);
    assert_eq!(total_bytes, 13);
    assert_eq!(data, b"phone\n");
}

#[test]
fn a_ranged_read_is_capped_per_event_so_a_large_file_takes_several_reads() {
    let browser = browser(pc());
    let mut received = 0usize;
    let mut offset = 0i64;
    while (offset as usize) < 200 * 1024 {
        let TerminalEvent::FileRange { data, .. } = range(&browser, "/C:/Users/me/long.log", offset) else {
            panic!("expected a range");
        };
        assert!(!data.is_empty() && data.len() <= 32 * 1024);
        received += data.len();
        offset += data.len() as i64;
    }
    assert_eq!(received, 200 * 1024);
}

#[test]
fn a_range_past_the_end_is_empty_rather_than_an_error() {
    let event = range(&browser(pc()), "/C:/Users/me/notes.txt", 500);
    assert!(matches!(&event, TerminalEvent::FileRange { data, .. } if data.is_empty()));
}

#[test]
fn a_missing_file_is_reported_as_no_longer_there() {
    let event = read(&browser(pc()), "/C:/Users/me/gone.txt");
    assert!(matches!(&event, TerminalEvent::BrowseFailure { .. }));
    assert_eq!(failure_message(&event), MISSING);

    let ranged = range(&browser(pc()), "/C:/Users/me/gone.txt", 0);
    assert_eq!(failure_message(&ranged), MISSING);
}

#[test]
fn a_folder_cannot_be_read_as_a_file() {
    let event = read(&browser(pc()), "/C:/Users/me");
    assert_eq!(failure_message(&event), NOT_A_FILE);
}

#[test]
fn a_relative_path_is_refused() {
    let browser = browser(pc());
    assert_eq!(failure_message(&list(&browser, Some("C:/Users"))), NOT_A_PATH);
    assert_eq!(failure_message(&read(&browser, "notes.txt")), NOT_A_PATH);
}

#[test]
fn a_path_that_steps_up_out_of_the_drive_is_refused() {
    let browser = browser(pc());
    assert_eq!(failure_message(&list(&browser, Some("/C:/Users/../../D:"))), NOT_A_PATH);
    assert_eq!(failure_message(&read(&browser, "/C:/Users/me/../../../secret.txt")), NOT_A_PATH);
    assert_eq!(failure_message(&range(&browser, "/C:/..", 0)), NOT_A_PATH);
}

#[test]
fn a_file_that_windows_will_not_open_is_reported_as_denied() {
    let mut fs = pc();
    fs.deny("C:\\Users\\Public");
    let browser = browser(fs);

    assert_eq!(failure_message(&list(&browser, Some("/C:/Users/Public"))), DENIED);
}

#[test]
fn a_binary_file_that_is_not_a_known_type_is_not_previewed_as_text() {
    let event = read(&browser(pc()), "/C:/Users/me/blob.bin");
    assert!(failure_message(&event).starts_with(NOT_TEXT_PREFIX));
}

#[test]
fn a_folder_too_big_for_one_frame_is_truncated_and_says_so() {
    let mut fs = InMemoryFileSystem::default();
    fs.add_folder("C:\\Big", 1.0);
    for index in 0..=MAXIMUM_LISTING_ENTRIES {
        fs.add_file(&format!("C:\\Big\\file{index:05}.txt"), b"x", 1.0);
    }
    let event = list(&FileBrowser::new(fs, "C:\\Big"), Some("/C:/Big"));

    let TerminalEvent::Directory { entries, truncated, .. } = event else {
        panic!("expected a directory");
    };
    assert!(entries.len() < MAXIMUM_LISTING_ENTRIES);
    assert!(truncated);
    let again = TerminalEvent::Directory { session_id: SESSION.to_owned(), path: "/C:/Big".to_owned(), entries, truncated };
    assert!(serde_json::to_vec(&again).expect("an event serialises").len() < 64 * 1024);
}

#[test]
fn a_folder_that_fits_one_frame_is_not_marked_truncated() {
    let mut fs = InMemoryFileSystem::default();
    fs.add_folder("C:\\Exact", 1.0);
    for index in 0..300 {
        fs.add_file(&format!("C:\\Exact\\file{index:05}.txt"), b"x", 1.0);
    }
    let event = list(&FileBrowser::new(fs, "C:\\Exact"), Some("/C:/Exact"));

    assert!(matches!(&event, TerminalEvent::Directory { truncated: false, entries, .. } if entries.len() == 300));
}

#[test]
fn a_folder_download_is_not_answered_by_the_browser_because_the_host_writes_the_zip() {
    let request = TerminalRequest::ArchiveFolder { session_id: SESSION.to_owned(), path: "/C:/Users/me".to_owned() };
    assert!(browser(pc()).answer(&request).is_none());
}
