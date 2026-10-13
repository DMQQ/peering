use peering_wire::files::{RemoteEntryKind, RemoteFileOperation};

use super::*;
use crate::files::fake_disk::FakeDisk;

const SESSION: &str = "0A1B2C3D-0000-4000-8000-00000000000F";

fn disk() -> FakeDisk {
    let mut disk = FakeDisk::default();
    disk.add_folder("C:\\Users\\me");
    disk.add_file("C:\\Users\\me\\a.txt", b"a");
    disk.add_folder("C:\\Users\\me\\Projects");
    disk.add_file("C:\\Users\\me\\Projects\\main.rs", b"fn main() {}");
    disk.add_file("C:\\Users\\me\\Projects\\lib.rs", b"");
    disk.protect("C:\\Users\\me");
    disk.protect("C:\\Windows");
    disk
}

fn run(disk: &mut FakeDisk, operation: RemoteFileOperation) -> TerminalEvent {
    change(disk, SESSION, &operation)
}

fn create(path: &str, kind: RemoteEntryKind) -> RemoteFileOperation {
    RemoteFileOperation::Create { path: path.to_owned(), kind }
}

fn rename(path: &str, to: &str) -> RemoteFileOperation {
    RemoteFileOperation::Rename { path: path.to_owned(), to: to.to_owned() }
}

fn delete(path: &str) -> RemoteFileOperation {
    RemoteFileOperation::Delete { path: path.to_owned() }
}

fn done(event: TerminalEvent) -> String {
    let TerminalEvent::FileOperationDone { note, .. } = event else { panic!("done, got {event:?}") };
    note
}

fn failed(event: TerminalEvent) -> String {
    let TerminalEvent::FileOperationFailure { message, .. } = event else { panic!("a failure, got {event:?}") };
    message
}

#[test]
fn a_new_folder_and_a_new_empty_file_are_made() {
    let mut disk = disk();
    assert_eq!(done(run(&mut disk, create("/C:/Users/me/Notes", RemoteEntryKind::Folder))), "created folder Notes");
    assert_eq!(done(run(&mut disk, create("/C:/Users/me/todo.txt", RemoteEntryKind::File))), "created file todo.txt");
    assert!(disk.is_folder("C:\\Users\\me\\Notes"));
    assert_eq!(disk.contents("C:\\Users\\me\\todo.txt"), Some(Vec::new()));
}

#[test]
fn creating_over_a_name_already_taken_changes_nothing() {
    let mut disk = disk();
    assert_eq!(failed(run(&mut disk, create("/C:/Users/me/a.txt", RemoteEntryKind::File))), NAME_TAKEN_BY_DISK);
    assert_eq!(disk.contents("C:\\Users\\me\\a.txt"), Some(b"a".to_vec()));
}

const NAME_TAKEN_BY_DISK: &str = "Something with that name is already there.";

#[test]
fn a_name_a_file_cannot_have_is_refused_before_the_disk_is_touched() {
    let mut disk = disk();
    for path in ["/C:/Users/me/con", "/C:/Users/me/x.", "/C:/Users/me/a*b", "/C:/Users/me/../x"] {
        assert!(!failed(run(&mut disk, create(path, RemoteEntryKind::File))).is_empty(), "{path}");
    }
    let too_long = format!("/C:/Users/me/{}", "n".repeat(256));
    assert_eq!(failed(run(&mut disk, create(&too_long, RemoteEntryKind::File))), NOT_A_NAME);
}

#[test]
fn a_path_that_is_not_absolute_or_is_a_drive_is_refused() {
    let mut disk = disk();
    for path in ["relative.txt", "/", "/C:"] {
        assert_eq!(failed(run(&mut disk, delete(path))), NOT_A_CHANGEABLE_PATH, "{path}");
    }
}

#[test]
fn creating_in_a_folder_that_is_gone_says_so() {
    let mut disk = disk();
    assert_eq!(failed(run(&mut disk, create("/C:/Users/me/Gone/x.txt", RemoteEntryKind::File))), FOLDER_GONE);
}

#[test]
fn a_rename_keeps_the_folder_and_answers_with_the_old_path() {
    let mut disk = disk();
    let event = run(&mut disk, rename("/C:/Users/me/a.txt", "b.txt"));
    assert_eq!(
        event,
        TerminalEvent::FileOperationDone {
            session_id: SESSION.to_owned(),
            path: "/C:/Users/me/a.txt".to_owned(),
            note: "renamed a.txt to b.txt".to_owned()
        }
    );
    assert!(disk.exists("C:\\Users\\me\\b.txt"));
    assert!(!disk.exists("C:\\Users\\me\\a.txt"));
}

#[test]
fn a_rename_cannot_move_a_file_to_another_folder() {
    let mut disk = disk();
    for to in ["..\\b.txt", "sub\\b.txt", "C:b.txt", "..", "", "b.txt "] {
        assert_eq!(failed(run(&mut disk, rename("/C:/Users/me/a.txt", to))), NOT_A_NAME, "{to:?}");
    }
    assert!(disk.exists("C:\\Users\\me\\a.txt"));
}

#[test]
fn a_rename_onto_a_name_already_taken_is_refused_and_replaces_nothing() {
    let mut disk = disk();
    assert_eq!(failed(run(&mut disk, rename("/C:/Users/me/a.txt", "projects"))), NAME_TAKEN);
    assert_eq!(disk.contents("C:\\Users\\me\\a.txt"), Some(b"a".to_vec()));
}

#[test]
fn a_rename_to_the_same_name_in_other_letters_is_allowed() {
    let mut disk = disk();
    assert_eq!(done(run(&mut disk, rename("/C:/Users/me/a.txt", "A.TXT"))), "renamed a.txt to A.TXT");
}

#[test]
fn a_rename_to_the_same_name_does_nothing() {
    let mut disk = disk();
    assert_eq!(done(run(&mut disk, rename("/C:/Users/me/a.txt", "a.txt"))), "renamed a.txt to a.txt");
}

#[test]
fn a_file_is_moved_to_the_recycle_bin_and_a_folder_counts_what_went_with_it() {
    let mut disk = disk();
    assert_eq!(done(run(&mut disk, delete("/C:/Users/me/a.txt"))), "moved a.txt to the Recycle Bin");
    assert_eq!(done(run(&mut disk, delete("/C:/Users/me/Projects"))), "moved Projects and 2 more to the Recycle Bin");
    assert_eq!(disk.recycled().len(), 2);
    assert!(!disk.exists("C:\\Users\\me\\Projects\\main.rs"));
}

#[test]
fn the_home_folder_and_anything_that_holds_it_cannot_be_deleted() {
    let mut disk = disk();
    for path in ["/C:/Users/me", "/C:/Users", "/C:/Windows", "/C:/users/ME"] {
        assert_eq!(failed(run(&mut disk, delete(path))), TOO_MUCH_TO_DELETE, "{path}");
    }
    assert!(disk.recycled().is_empty());
}

#[test]
fn deleting_something_already_gone_says_so() {
    let mut disk = disk();
    assert_eq!(failed(run(&mut disk, delete("/C:/Users/me/ghost.txt"))), NOTHING_THERE);
}
