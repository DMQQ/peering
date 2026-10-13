use super::*;
use crate::files::fake_disk::FakeDisk;

const SESSION: &str = "0A1B2C3D-0000-4000-8000-00000000000F";
const PATH: &str = "/C:/Users/me/report.txt";
const NATIVE: &str = "C:\\Users\\me\\report.txt";

fn transfers() -> Transfers<FakeDisk, &'static str> {
    let mut disk = FakeDisk::default();
    disk.add_folder("C:\\Users\\me");
    let mut counter = 0;
    Transfers::new(
        disk,
        Box::new(move || {
            counter += 1;
            format!("ID{counter}")
        }),
    )
}

fn failure_message(event: Option<TerminalEvent>) -> String {
    let Some(TerminalEvent::WriteFailure { message, .. }) = event else { panic!("a write failure, got {event:?}") };
    message
}

#[test]
fn an_upload_lands_in_one_move_when_every_byte_has_arrived() {
    let mut transfers = transfers();
    assert_eq!(transfers.begin("a", SESSION, PATH, 10, 0.0), None);
    assert_eq!(transfers.write(SESSION, PATH, b"hello", false, 1.0), None);
    assert!(transfers.disk().contents(NATIVE).is_none(), "nothing is at the destination yet");
    let done = transfers.write(SESSION, PATH, b"world", true, 2.0);
    assert_eq!(done, Some(TerminalEvent::WroteFile { session_id: SESSION.to_owned(), path: PATH.to_owned(), total_bytes: 10 }));
    assert_eq!(transfers.disk().contents(NATIVE), Some(b"helloworld".to_vec()));
    assert!(transfers.disk().staging_files().is_empty());
    assert_eq!(transfers.in_progress(), 0);
}

#[test]
fn the_scratch_file_is_hidden_beside_the_destination_and_its_folder_is_remembered() {
    let mut transfers = transfers();
    transfers.begin("a", SESSION, PATH, 3, 0.0);
    transfers.write(SESSION, PATH, b"abc", false, 1.0);
    assert_eq!(transfers.disk().staging_files(), ["c:\\users\\me\\.report.txt.peering-id1.part"]);
    assert_eq!(transfers.disk().remembered_folders(), ["C:\\Users\\me"]);
}

#[test]
fn an_existing_file_is_replaced_whole_and_not_before() {
    let mut transfers = transfers();
    transfers.disk().add_file(NATIVE, b"old contents");
    transfers.begin("a", SESSION, PATH, 3, 0.0);
    transfers.write(SESSION, PATH, b"new", false, 1.0);
    assert_eq!(transfers.disk().contents(NATIVE), Some(b"old contents".to_vec()));
    transfers.write(SESSION, PATH, b"", true, 2.0);
    assert_eq!(transfers.disk().contents(NATIVE), Some(b"new".to_vec()));
}

#[test]
fn an_empty_file_is_written_by_a_last_piece_with_no_bytes() {
    let mut transfers = transfers();
    transfers.begin("a", SESSION, PATH, 0, 0.0);
    let done = transfers.write(SESSION, PATH, b"", true, 1.0);
    assert!(matches!(done, Some(TerminalEvent::WroteFile { total_bytes: 0, .. })));
    assert_eq!(transfers.disk().contents(NATIVE), Some(Vec::new()));
}

#[test]
fn a_path_that_is_not_absolute_or_names_a_device_is_refused() {
    let mut transfers = transfers();
    for path in ["report.txt", "/", "/C:", "/C:/Users/me/con", "/C:/Users/me/../x", "/C:/a|b"] {
        assert_eq!(failure_message(transfers.begin("a", SESSION, path, 1, 0.0)), NOT_A_WRITABLE_PATH, "{path}");
    }
    assert_eq!(transfers.in_progress(), 0);
}

#[test]
fn a_file_over_the_size_limit_or_of_negative_size_is_refused() {
    let mut transfers = transfers();
    assert_eq!(failure_message(transfers.begin("a", SESSION, PATH, MAXIMUM_WRITE_BYTES + 1, 0.0)), TOO_LARGE);
    assert_eq!(failure_message(transfers.begin("a", SESSION, PATH, -1, 0.0)), TOO_LARGE);
    assert_eq!(transfers.begin("a", SESSION, PATH, MAXIMUM_WRITE_BYTES, 0.0), None);
}

#[test]
fn a_ninth_transfer_is_refused_but_a_second_for_the_same_path_replaces_the_first() {
    let mut transfers = transfers();
    for number in 0..MAXIMUM_CONCURRENT_TRANSFERS {
        assert_eq!(transfers.begin("a", SESSION, &format!("/C:/Users/me/f{number}.txt"), 1, 0.0), None);
    }
    assert_eq!(failure_message(transfers.begin("a", SESSION, "/C:/Users/me/extra.txt", 1, 0.0)), BUSY);
    assert_eq!(transfers.begin("a", SESSION, "/C:/Users/me/F0.TXT", 1, 0.0), None, "the same path in other letters");
    assert_eq!(transfers.in_progress(), MAXIMUM_CONCURRENT_TRANSFERS);
}

#[test]
fn a_replaced_transfer_leaves_no_scratch_file_behind() {
    let mut transfers = transfers();
    transfers.begin("a", SESSION, PATH, 5, 0.0);
    transfers.write(SESSION, PATH, b"abc", false, 1.0);
    transfers.begin("a", SESSION, PATH, 5, 2.0);
    assert!(transfers.disk().staging_files().is_empty());
}

#[test]
fn a_piece_for_a_transfer_nobody_began_is_refused() {
    let mut transfers = transfers();
    assert_eq!(failure_message(transfers.write(SESSION, PATH, b"x", false, 0.0)), GONE);
}

#[test]
fn a_piece_over_32_kilobytes_ends_the_transfer() {
    let mut transfers = transfers();
    transfers.begin("a", SESSION, PATH, 100_000, 0.0);
    let piece = vec![0u8; WRITE_CHUNK_BYTES + 1];
    assert_eq!(failure_message(transfers.write(SESSION, PATH, &piece, false, 1.0)), OVERSIZED_PIECE);
    assert_eq!(transfers.in_progress(), 0);
}

#[test]
fn a_transfer_that_sends_more_than_it_said_is_ended_and_leaves_nothing() {
    let mut transfers = transfers();
    transfers.begin("a", SESSION, PATH, 4, 0.0);
    transfers.write(SESSION, PATH, b"abc", false, 1.0);
    assert_eq!(failure_message(transfers.write(SESSION, PATH, b"de", true, 2.0)), SENT_TOO_MUCH);
    assert!(transfers.disk().staging_files().is_empty());
    assert!(transfers.disk().contents(NATIVE).is_none());
}

#[test]
fn a_last_piece_that_leaves_the_file_short_is_a_failure_and_not_a_short_file() {
    let mut transfers = transfers();
    transfers.disk().add_file(NATIVE, b"old");
    transfers.begin("a", SESSION, PATH, 10, 0.0);
    assert_eq!(failure_message(transfers.write(SESSION, PATH, b"abc", true, 1.0)), STOPPED_EARLY);
    assert_eq!(transfers.disk().contents(NATIVE), Some(b"old".to_vec()), "the destination is as it was");
    assert!(transfers.disk().staging_files().is_empty());
}

#[test]
fn a_destination_that_became_a_folder_is_not_written_over() {
    let mut transfers = transfers();
    transfers.begin("a", SESSION, PATH, 1, 0.0);
    transfers.disk().add_folder(NATIVE);
    assert_eq!(failure_message(transfers.write(SESSION, PATH, b"x", true, 1.0)), IS_A_FOLDER);
    assert!(transfers.disk().is_folder(NATIVE));
    assert!(transfers.disk().staging_files().is_empty());
}

#[test]
fn a_disk_that_refuses_a_piece_ends_the_transfer_with_its_reason() {
    let mut transfers = transfers();
    transfers.begin("a", SESSION, PATH, 6, 0.0);
    transfers.disk().fail_appends_with("There is not enough room on this PC to save that.");
    let message = failure_message(transfers.write(SESSION, PATH, b"abc", false, 1.0));
    assert!(message.contains("not enough room"));
    assert_eq!(transfers.in_progress(), 0);
    assert!(transfers.disk().staging_files().is_empty());
}

#[test]
fn a_move_that_fails_removes_the_scratch_file_and_says_why() {
    let mut transfers = transfers();
    transfers.begin("a", SESSION, PATH, 1, 0.0);
    transfers.disk().fail_commits_with("Peering is not allowed to change that file.");
    assert!(failure_message(transfers.write(SESSION, PATH, b"x", true, 1.0)).contains("not allowed"));
    assert!(transfers.disk().staging_files().is_empty());
}

#[test]
fn a_transfer_that_goes_quiet_is_dropped_after_ninety_seconds_and_its_owner_is_told() {
    let mut transfers = transfers();
    transfers.begin("phone one", SESSION, PATH, 10, 0.0);
    transfers.write(SESSION, PATH, b"abc", false, 10.0);
    assert!(transfers.drop_idle(99.0).is_empty());
    let dropped = transfers.drop_idle(100.0);
    assert_eq!(dropped.len(), 1);
    assert_eq!(dropped[0].0, "phone one");
    assert_eq!(failure_message(Some(dropped[0].1.clone())), DROPPED_IDLE);
    assert!(transfers.disk().staging_files().is_empty());
    assert_eq!(transfers.in_progress(), 0);
}

#[test]
fn a_piece_resets_the_idle_clock() {
    let mut transfers = transfers();
    transfers.begin("a", SESSION, PATH, 10, 0.0);
    transfers.write(SESSION, PATH, b"abc", false, 80.0);
    assert!(transfers.drop_idle(150.0).is_empty());
}

#[test]
fn a_transfer_stopped_from_outside_is_discarded_and_reported() {
    let mut transfers = transfers();
    transfers.begin("a", SESSION, PATH, 10, 0.0);
    transfers.write(SESSION, PATH, b"abc", false, 1.0);
    assert_eq!(failure_message(Some(transfers.stop(SESSION, PATH, DISK_BEHIND))), DISK_BEHIND);
    assert!(transfers.disk().staging_files().is_empty());
}

#[test]
fn the_queued_bytes_budget_refuses_past_sixteen_megabytes_and_forgives_what_was_written() {
    let mut budget = QueuedByteBudget::default();
    assert!(budget.reserve(MAXIMUM_QUEUED_BYTES));
    assert!(!budget.reserve(1));
    budget.release(1024);
    assert!(budget.reserve(1024));
    budget.release(usize::MAX);
    assert!(budget.reserve(MAXIMUM_QUEUED_BYTES));
}

#[test]
fn only_a_scratch_file_made_by_an_upload_is_recognised_as_one() {
    assert!(is_staging_file(".report.txt.peering-0A1B2C3D-0000-4000-8000-00000000000F.part"));
    assert!(is_staging_file(".a.b.peering-0a1b2c3d-0000-4000-8000-00000000000f.part"));
    for name in [
        "report.txt.peering-0A1B2C3D-0000-4000-8000-00000000000F.part",
        ".report.txt.peering-0A1B2C3D-0000-4000-8000-00000000000F",
        ".report.txt.peering-not-a-uuid.part",
        ".notes.part",
        ".report.txt.part",
        "",
    ] {
        assert!(!is_staging_file(name), "{name}");
    }
}
