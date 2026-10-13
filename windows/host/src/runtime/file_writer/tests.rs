use std::sync::mpsc::{channel, Receiver};
use std::time::Duration;

use peering_core::files::fake_disk::SharedFakeDisk;
use peering_core::files::transfer::{MAXIMUM_QUEUED_BYTES, WRITE_CHUNK_BYTES};
use peering_wire::files::RemoteEntryKind;

use super::*;

const SESSION: &str = "browse-1";
const PATH: &str = "/C:/Users/me/report.txt";
const NATIVE: &str = "C:\\Users\\me\\report.txt";

struct Rig {
    writer: FileWriter,
    disk: SharedFakeDisk,
    reply: Reply,
    events: Receiver<TerminalEvent>,
}

fn rig() -> Rig {
    let disk = SharedFakeDisk::default();
    disk.with(|disk| {
        disk.add_folder("C:\\Users\\me");
        disk.protect("C:\\Users\\me");
    });
    let mut counter = 0;
    let writer = FileWriter::start(
        Box::new(disk.clone()),
        Box::new(move || {
            counter += 1;
            format!("00000000-0000-4000-8000-{counter:012}")
        }),
    )
    .expect("the writer thread starts");
    let (sender, events) = channel();
    let sender = std::sync::Mutex::new(sender);
    let reply: Reply = Arc::new(move |event| {
        let _delivered = sender.lock().expect("not poisoned").send(event);
    });
    Rig { writer, disk, reply, events }
}

impl Rig {
    fn submit(&self, request: TerminalRequest) -> bool {
        self.writer.submit(&request, &self.reply)
    }

    fn next(&self) -> TerminalEvent {
        self.events.recv_timeout(Duration::from_secs(5)).expect("the writer answers")
    }
}

fn begin(total_bytes: i64) -> TerminalRequest {
    TerminalRequest::BeginWrite { session_id: SESSION.to_owned(), path: PATH.to_owned(), total_bytes }
}

fn piece(data: &[u8], is_last: bool) -> TerminalRequest {
    TerminalRequest::WriteChunk { session_id: SESSION.to_owned(), path: PATH.to_owned(), data: data.to_vec(), is_last }
}

#[test]
fn an_upload_in_pieces_is_written_in_order_and_answered_once() {
    let rig = rig();
    assert!(rig.submit(begin(9)));
    assert!(rig.submit(piece(b"abc", false)));
    assert!(rig.submit(piece(b"def", false)));
    assert!(rig.submit(piece(b"ghi", true)));
    assert_eq!(rig.next(), TerminalEvent::WroteFile { session_id: SESSION.to_owned(), path: PATH.to_owned(), total_bytes: 9 });
    assert_eq!(rig.disk.with(|disk| disk.contents(NATIVE)), Some(b"abcdefghi".to_vec()));
}

#[test]
fn a_request_that_is_not_a_write_is_left_to_the_caller() {
    let rig = rig();
    assert!(!rig.submit(TerminalRequest::List {}));
    assert!(!rig.submit(TerminalRequest::ListDirectory { session_id: SESSION.to_owned(), path: None }));
}

#[test]
fn a_refused_upload_is_answered_with_its_reason() {
    let rig = rig();
    rig.submit(begin(-5));
    assert!(matches!(rig.next(), TerminalEvent::WriteFailure { .. }));
}

#[test]
fn a_new_folder_is_made_and_answered() {
    let rig = rig();
    rig.submit(TerminalRequest::ChangeFile {
        session_id: SESSION.to_owned(),
        operation: RemoteFileOperation::Create { path: "/C:/Users/me/Notes".to_owned(), kind: RemoteEntryKind::Folder },
    });
    assert!(matches!(rig.next(), TerminalEvent::FileOperationDone { .. }));
    assert!(rig.disk.with(|disk| disk.is_folder("C:\\Users\\me\\Notes")));
}

#[test]
fn a_delete_of_a_protected_folder_is_answered_with_a_failure_and_nothing_moves() {
    let rig = rig();
    rig.submit(TerminalRequest::ChangeFile {
        session_id: SESSION.to_owned(),
        operation: RemoteFileOperation::Delete { path: "/C:/Users/me".to_owned() },
    });
    assert!(matches!(rig.next(), TerminalEvent::FileOperationFailure { .. }));
    assert!(rig.disk.with(|disk| disk.recycled().is_empty()));
}

#[test]
fn pieces_beyond_the_queue_budget_stop_the_transfer_with_a_reason() {
    let rig = rig();
    rig.submit(begin(100_000_000));
    // Reserved by hand, so the next piece finds the budget spent without a race against the writer thread.
    assert!(rig.writer.reserve(MAXIMUM_QUEUED_BYTES));
    rig.submit(piece(&[0; 10], false));
    let TerminalEvent::WriteFailure { message, .. } = rig.next() else { panic!("a write failure") };
    assert!(message.contains("not keeping up"));
    assert!(rig.disk.with(|disk| disk.staging_files().is_empty()));
}

#[test]
fn a_piece_the_writer_took_gives_its_bytes_back_to_the_budget() {
    let rig = rig();
    rig.submit(begin(WRITE_CHUNK_BYTES as i64));
    rig.submit(piece(&vec![1; WRITE_CHUNK_BYTES], true));
    rig.next();
    assert!(rig.writer.reserve(MAXIMUM_QUEUED_BYTES), "everything reserved was released");
}

#[test]
fn a_writer_that_has_stopped_answers_with_a_failure_instead_of_silence() {
    let (jobs, inbox) = channel::<Job>();
    drop(inbox);
    let (sender, events) = channel();
    let sender = std::sync::Mutex::new(sender);
    let reply: Reply = Arc::new(move |event| {
        let _delivered = sender.lock().expect("not poisoned").send(event);
    });
    let writer = FileWriter {
        jobs,
        budget: Arc::new(Mutex::new(QueuedByteBudget::default())),
        _thread: thread::spawn(|| {}),
    };
    assert!(writer.submit(&begin(1), &reply));
    assert!(matches!(events.recv_timeout(Duration::from_secs(1)), Ok(TerminalEvent::WriteFailure { .. })));
}
