use super::*;

fn folder(name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!("peering-log-{name}-{}", std::process::id()));
    drop(fs::remove_dir_all(&path));
    path
}

fn read(directory: &Path, name: &str) -> String {
    fs::read_to_string(directory.join(name)).unwrap_or_default()
}

#[test]
fn a_line_is_stamped_with_the_time_and_ends_with_a_newline() {
    let directory = folder("stamp");
    let mut log = LogFile::open(&directory).expect("a log");
    log.write_line(1_791_892_800, "the relay connected").expect("written");
    assert_eq!(read(&directory, FILE_NAME), "2026-10-13T12:00:00Z the relay connected\n");
    drop(fs::remove_dir_all(directory));
}

#[test]
fn a_message_of_several_lines_stays_one_line() {
    let directory = folder("lines");
    let mut log = LogFile::open(&directory).expect("a log");
    log.write_line(0, "first\r\nsecond\nthird").expect("written");
    assert_eq!(read(&directory, FILE_NAME).lines().count(), 1);
    drop(fs::remove_dir_all(directory));
}

#[test]
fn a_restart_continues_the_file() {
    let directory = folder("restart");
    LogFile::open(&directory).expect("a log").write_line(0, "one").expect("written");
    LogFile::open(&directory).expect("a log").write_line(1, "two").expect("written");
    assert_eq!(read(&directory, FILE_NAME).lines().count(), 2);
    drop(fs::remove_dir_all(directory));
}

#[test]
fn a_full_file_becomes_the_first_older_file_and_a_new_one_starts() {
    let directory = folder("rotate");
    let mut log = LogFile::open_with(&directory, 100).expect("a log");
    for number in 0..6 {
        log.write_line(0, &format!("line number {number}")).expect("written");
    }
    assert!(read(&directory, &format!("{FILE_NAME}.1")).contains("line number"));
    assert!(read(&directory, FILE_NAME).contains("line number 5"));
    assert!(read(&directory, FILE_NAME).len() <= 100);
    drop(fs::remove_dir_all(directory));
}

#[test]
fn only_the_three_older_files_are_kept() {
    let directory = folder("keep");
    let mut log = LogFile::open_with(&directory, 60).expect("a log");
    for number in 0..40 {
        log.write_line(0, &format!("line {number:02}")).expect("written");
    }
    for kept in ["", ".1", ".2", ".3"] {
        assert!(directory.join(format!("{FILE_NAME}{kept}")).exists(), "{kept}");
    }
    assert!(!directory.join(format!("{FILE_NAME}.4")).exists());
    assert!(read(&directory, &format!("{FILE_NAME}.3")).contains("line"), "the oldest kept file is not the first one written");
    assert!(!read(&directory, &format!("{FILE_NAME}.3")).contains("line 00"));
    drop(fs::remove_dir_all(directory));
}

#[test]
fn a_line_longer_than_the_limit_is_written_whole_into_a_file_of_its_own() {
    let directory = folder("long");
    let mut log = LogFile::open_with(&directory, 50).expect("a log");
    log.write_line(0, "short").expect("written");
    log.write_line(0, &"x".repeat(200)).expect("written");
    assert!(read(&directory, FILE_NAME).contains(&"x".repeat(200)));
    assert!(read(&directory, &format!("{FILE_NAME}.1")).contains("short"));
    drop(fs::remove_dir_all(directory));
}

#[test]
fn a_folder_that_cannot_be_made_is_an_error() {
    let directory = folder("blocked");
    fs::create_dir_all(&directory).expect("a folder");
    let blocker = directory.join("file");
    fs::write(&blocker, b"x").expect("a file");
    assert!(LogFile::open(&blocker.join("logs")).is_err());
    drop(fs::remove_dir_all(directory));
}
