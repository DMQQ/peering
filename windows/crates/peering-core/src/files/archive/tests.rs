use super::super::fake::InMemoryFileSystem;
use super::super::zip::tests::read_back;
use super::*;

fn project() -> InMemoryFileSystem {
    let mut fs = InMemoryFileSystem::default();
    fs.add_folder("C:\\Users\\me\\Project", 0.0);
    fs.add_file("C:\\Users\\me\\Project\\readme.txt", b"read me", 0.0);
    fs.add_file("C:\\Users\\me\\Project\\src\\main.rs", b"fn main() {}", 0.0);
    fs.add_file("C:\\Users\\me\\Project\\src\\deep\\more.rs", b"// more", 0.0);
    fs.add_folder("C:\\Users\\me\\Project\\empty", 0.0);
    fs
}

/// Bytes deflate cannot shrink.
fn noise(length: usize) -> Vec<u8> {
    let mut state = 0x9E37_79B9_7F4A_7C15u64;
    (0..length)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            (state >> 24) as u8
        })
        .collect()
}

fn archive(fs: &InMemoryFileSystem, limit: u64) -> Result<(ArchiveSummary, Vec<u8>), ArchiveError> {
    write_archive(fs, "C:\\Users\\me\\Project", "Project", Vec::new(), limit)
}

#[test]
fn the_folder_keeps_its_own_name_as_the_top_of_the_zip() {
    let (summary, bytes) = archive(&project(), MAXIMUM_ARCHIVE_BYTES).expect("a zip");
    let found = read_back(&bytes);
    let mut names: Vec<&str> = found.iter().map(|entry| entry.name.as_str()).collect();
    names.sort_unstable();
    assert_eq!(
        names,
        ["Project/", "Project/empty/", "Project/readme.txt", "Project/src/", "Project/src/deep/", "Project/src/deep/more.rs", "Project/src/main.rs"]
    );
    assert_eq!(summary.entries, 7);
    assert_eq!((summary.bytes, summary.skipped), (bytes.len() as u64, 0));
}

#[test]
fn every_file_comes_back_byte_for_byte() {
    let (_, bytes) = archive(&project(), MAXIMUM_ARCHIVE_BYTES).expect("a zip");
    let found = read_back(&bytes);
    let content = |name: &str| found.iter().find(|entry| entry.name == name).map(|entry| entry.content.clone());
    assert_eq!(content("Project/readme.txt").as_deref(), Some(&b"read me"[..]));
    assert_eq!(content("Project/src/deep/more.rs").as_deref(), Some(&b"// more"[..]));
}

#[test]
fn folders_are_marked_as_folders() {
    let (_, bytes) = archive(&project(), MAXIMUM_ARCHIVE_BYTES).expect("a zip");
    for entry in read_back(&bytes) {
        assert_eq!(entry.folder, entry.name.ends_with('/'), "{}", entry.name);
    }
}

#[test]
fn a_file_that_cannot_be_opened_is_left_out_and_counted() {
    let mut fs = project();
    fs.deny("C:\\Users\\me\\Project\\readme.txt");
    let (summary, bytes) = archive(&fs, MAXIMUM_ARCHIVE_BYTES).expect("a zip without it");
    assert_eq!(summary.skipped, 1);
    assert!(read_back(&bytes).iter().all(|entry| entry.name != "Project/readme.txt"));
}

#[test]
fn a_folder_that_cannot_be_listed_is_left_empty_and_counted() {
    let mut fs = project();
    fs.deny("C:\\Users\\me\\Project\\src");
    let (summary, bytes) = archive(&fs, MAXIMUM_ARCHIVE_BYTES).expect("a zip without its contents");
    assert_eq!(summary.skipped, 1);
    assert!(read_back(&bytes).iter().all(|entry| !entry.name.starts_with("Project/src/") || entry.name == "Project/src/"));
}

#[test]
fn a_zip_past_the_cap_is_refused() {
    let mut fs = project();
    let noise = noise(100_000);
    fs.add_file("C:\\Users\\me\\Project\\noise.bin", &noise, 0.0);
    assert_eq!(archive(&fs, 10_000).map(|_| ()), Err(ArchiveError::TooLarge));
}

#[test]
fn a_file_is_not_a_folder() {
    let fs = project();
    let result = write_archive(&fs, "C:\\Users\\me\\Project\\readme.txt", "readme.txt", Vec::new(), MAXIMUM_ARCHIVE_BYTES);
    assert_eq!(result.map(|_| ()), Err(ArchiveError::NotAFolder));
}

#[test]
fn a_folder_that_is_not_there_is_a_failure() {
    let fs = project();
    let result = write_archive(&fs, "C:\\Nope", "Nope", Vec::new(), MAXIMUM_ARCHIVE_BYTES);
    assert!(matches!(result, Err(ArchiveError::Failed(_))));
}

#[test]
fn an_archive_of_many_small_files_stops_at_the_most_a_zip_can_name() {
    let mut fs = InMemoryFileSystem::default();
    fs.add_folder("C:\\Many", 0.0);
    for number in 0..(MAXIMUM_ENTRIES + 5) {
        fs.add_file(&format!("C:\\Many\\f{number}"), b"x", 0.0);
    }
    let result = write_archive(&fs, "C:\\Many", "Many", Vec::new(), u64::MAX);
    assert_eq!(result.map(|_| ()), Err(ArchiveError::TooLarge));
}

#[test]
fn a_drive_root_is_archived_under_the_name_it_is_given() {
    let mut fs = InMemoryFileSystem::default();
    fs.add_file("D:\\notes.txt", b"n", 0.0);
    let (_, bytes) = write_archive(&fs, "D:\\", "Drive D", Vec::new(), MAXIMUM_ARCHIVE_BYTES).expect("a zip");
    let names: Vec<String> = read_back(&bytes).into_iter().map(|entry| entry.name).collect();
    assert!(names.contains(&"Drive D/notes.txt".to_owned()), "{names:?}");
}
