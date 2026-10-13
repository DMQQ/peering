use std::sync::{Arc, Mutex};

use super::*;

struct RecordingBin(Arc<Mutex<Vec<String>>>);

impl Recycle for RecordingBin {
    fn recycle(&self, path: &str) -> Result<(), String> {
        self.0.lock().expect("not poisoned").push(path.to_owned());
        Ok(())
    }
}

fn folder(name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!("peering-disk-{name}-{}", std::process::id()));
    drop(fs::remove_dir_all(&path));
    fs::create_dir_all(&path).expect("a temporary folder");
    path
}

fn text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn disk(staging_list: Option<PathBuf>) -> (StdDisk, Arc<Mutex<Vec<String>>>) {
    let recycled = Arc::new(Mutex::new(Vec::new()));
    (StdDisk::new(Box::new(RecordingBin(recycled.clone())), vec!["protected".to_owned()], staging_list), recycled)
}

#[test]
fn a_scratch_file_is_built_up_and_moved_over_the_destination() {
    let directory = folder("commit");
    let (mut disk, _) = disk(None);
    let staging = text(&directory.join(".a.txt.peering-X.part"));
    let target = text(&directory.join("a.txt"));
    fs::write(&target, "old").expect("an old file");
    disk.create_staging(&staging).expect("created");
    disk.append(&staging, b"hello ").expect("appended");
    disk.append(&staging, b"world").expect("appended");
    assert_eq!(fs::read_to_string(&target).expect("still old"), "old");
    assert_eq!(disk.commit(&staging, &target), Ok(11));
    assert_eq!(fs::read_to_string(&target).expect("replaced"), "hello world");
    assert!(!Path::new(&staging).exists());
    drop(fs::remove_dir_all(directory));
}

#[test]
fn a_scratch_file_that_is_already_there_is_not_overwritten() {
    let directory = folder("exclusive");
    let (mut disk, _) = disk(None);
    let staging = text(&directory.join("s.part"));
    fs::write(&staging, "someone else's").expect("a file");
    assert!(disk.create_staging(&staging).is_err());
    assert_eq!(fs::read_to_string(&staging).expect("untouched"), "someone else's");
    drop(fs::remove_dir_all(directory));
}

#[test]
fn a_discarded_scratch_file_is_removed_and_a_missing_one_is_fine() {
    let directory = folder("discard");
    let (mut disk, _) = disk(None);
    let staging = text(&directory.join("s.part"));
    disk.create_staging(&staging).expect("created");
    disk.discard(&staging);
    assert!(!Path::new(&staging).exists());
    disk.discard(&staging);
    drop(fs::remove_dir_all(directory));
}

#[test]
fn a_new_file_is_never_made_over_an_existing_one() {
    let directory = folder("exclusive-file");
    let (mut disk, _) = disk(None);
    let path = text(&directory.join("a.txt"));
    fs::write(&path, "mine").expect("a file");
    assert_eq!(disk.make_file(&path), Err(DiskError("Something with that name is already there.".to_owned())));
    assert_eq!(fs::read_to_string(&path).expect("untouched"), "mine");
    assert!(disk.make_folder(&text(&directory)).is_err());
    drop(fs::remove_dir_all(directory));
}

#[test]
fn what_is_at_a_path_is_told_without_following_a_link() {
    let directory = folder("existing");
    let (disk, _) = disk(None);
    fs::write(directory.join("f"), "x").expect("a file");
    fs::create_dir(directory.join("d")).expect("a folder");
    assert_eq!(disk.existing(&text(&directory.join("f"))), Ok(Existing::File));
    assert_eq!(disk.existing(&text(&directory.join("d"))), Ok(Existing::Folder));
    assert_eq!(disk.existing(&text(&directory.join("none"))), Ok(Existing::Nothing));
    drop(fs::remove_dir_all(directory));
}

#[test]
fn a_folder_is_counted_with_everything_inside_it() {
    let directory = folder("count");
    let (disk, _) = disk(None);
    fs::create_dir_all(directory.join("a").join("b")).expect("folders");
    fs::write(directory.join("a").join("one"), "1").expect("a file");
    fs::write(directory.join("a").join("b").join("two"), "2").expect("a file");
    assert_eq!(disk.count_inside(&text(&directory.join("a"))), Some(4));
    drop(fs::remove_dir_all(directory));
}

#[test]
fn a_delete_goes_through_the_recycler_and_not_the_filesystem() {
    let directory = folder("recycle");
    let (mut disk, recycled) = disk(None);
    let path = text(&directory.join("keep.txt"));
    fs::write(&path, "x").expect("a file");
    disk.recycle(&path).expect("recorded");
    assert!(Path::new(&path).exists(), "the recording bin moved nothing");
    assert_eq!(*recycled.lock().expect("not poisoned"), vec![path]);
    drop(fs::remove_dir_all(directory));
}

#[test]
fn scratch_files_left_by_a_crash_are_swept_and_nothing_else_is() {
    let directory = folder("sweep");
    let list = directory.join("folders.txt");
    let uploads = directory.join("uploads");
    fs::create_dir(&uploads).expect("a folder");
    let orphan = uploads.join(".report.txt.peering-0A1B2C3D-0000-4000-8000-00000000000F.part");
    let theirs = uploads.join(".report.txt.part");
    fs::write(&orphan, "half").expect("a file");
    fs::write(&theirs, "not ours").expect("a file");
    let (mut disk, _) = disk(Some(list.clone()));
    disk.remember_staging_folder(&text(&uploads));
    disk.remember_staging_folder(&text(&uploads));
    assert_eq!(fs::read_to_string(&list).expect("a list").lines().count(), 1, "a folder is listed once");
    disk.sweep_orphans();
    assert!(!orphan.exists());
    assert!(theirs.exists());
    assert!(!list.exists(), "the list is spent");
    drop(fs::remove_dir_all(directory));
}

#[test]
fn only_the_last_fifty_folders_are_remembered() {
    let directory = folder("remember");
    let list = directory.join("folders.txt");
    let (mut disk, _) = disk(Some(list.clone()));
    for number in 0..60 {
        disk.remember_staging_folder(&format!("C:\\Folder{number}"));
    }
    let remembered = fs::read_to_string(&list).expect("a list");
    assert_eq!(remembered.lines().count(), 50);
    assert!(remembered.contains("Folder59") && !remembered.contains("Folder9\n") && !remembered.contains("Folder0\n"));
    drop(fs::remove_dir_all(directory));
}

#[test]
fn disk_errors_become_sentences_for_the_phone() {
    let denied = io::Error::from(io::ErrorKind::PermissionDenied);
    assert!(message_for(&denied).contains("not allowed"));
    assert_eq!(message_for(&io::Error::from(io::ErrorKind::NotFound)), "That folder is no longer there.");
    assert!(message_for(&io::Error::from_raw_os_error(112)).contains("not enough room"));
    assert!(message_for(&io::Error::from_raw_os_error(32)).contains("Another program"));
    assert!(message_for(&io::Error::from_raw_os_error(183)).contains("already there"));
}

#[test]
fn the_protected_folders_are_the_ones_the_environment_names() {
    let get = |name: &str| match name {
        "USERPROFILE" => Some("C:\\Users\\me".to_owned()),
        "SystemRoot" => Some("C:\\Windows".to_owned()),
        "ProgramFiles" => Some(String::new()),
        _ => None,
    };
    assert_eq!(protected_folders(&get), ["C:\\Users\\me", "C:\\Windows"]);
}
