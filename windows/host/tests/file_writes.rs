//! A phone sending files to the PC and changing what is there, over a paired connection.

mod support;

use peering_wire::files::{RemoteEntryKind, RemoteFileOperation};
use peering_wire::framing::MessageKind;
use peering_wire::terminal::{TerminalEvent, TerminalRequest};
use support::*;

const SCOPE: &str = "browse-1";

async fn browsing_phone(harness: &Harness) -> Phone {
    let mut phone = paired_phone(&harness.runtime).await;
    phone.send_json(MessageKind::TerminalRequest, &TerminalRequest::StartBrowser { id: SCOPE.to_owned() }).await;
    phone
}

async fn ask(phone: &mut Phone, request: TerminalRequest) -> TerminalEvent {
    phone.send_json(MessageKind::TerminalRequest, &request).await;
    decode_json(&phone.next_of(MessageKind::TerminalEvent).await)
}

fn begin(path: &str, total_bytes: i64) -> TerminalRequest {
    TerminalRequest::BeginWrite { session_id: SCOPE.to_owned(), path: path.to_owned(), total_bytes }
}

fn piece(path: &str, data: &[u8], is_last: bool) -> TerminalRequest {
    TerminalRequest::WriteChunk { session_id: SCOPE.to_owned(), path: path.to_owned(), data: data.to_vec(), is_last }
}

#[test]
fn an_uploaded_file_arrives_whole_and_is_confirmed() {
    run(async {
        let harness = harness();
        let mut phone = browsing_phone(&harness).await;
        let path = "/C:/Users/me/upload.bin";
        phone.send_json(MessageKind::TerminalRequest, &begin(path, 6)).await;
        phone.send_json(MessageKind::TerminalRequest, &piece(path, b"abc", false)).await;
        let event = ask(&mut phone, piece(path, b"def", true)).await;
        assert_eq!(event, TerminalEvent::WroteFile { session_id: SCOPE.to_owned(), path: path.to_owned(), total_bytes: 6 });
        assert_eq!(harness.disk.with(|disk| disk.contents("C:\\Users\\me\\upload.bin")), Some(b"abcdef".to_vec()));
    });
}

#[test]
fn an_upload_that_names_a_path_outside_a_drive_is_refused_and_writes_nothing() {
    run(async {
        let harness = harness();
        let mut phone = browsing_phone(&harness).await;
        for path in ["/C:/Users/me/../../Windows/x.dll", "relative.txt", "/C:/Users/me/con.txt"] {
            let event = ask(&mut phone, begin(path, 1)).await;
            assert!(matches!(event, TerminalEvent::WriteFailure { .. }), "{path}");
        }
        assert!(harness.disk.with(|disk| disk.staging_files().is_empty()));
    });
}

#[test]
fn an_upload_over_two_gigabytes_is_refused_before_anything_travels() {
    run(async {
        let harness = harness();
        let mut phone = browsing_phone(&harness).await;
        let event = ask(&mut phone, begin("/C:/Users/me/huge.bin", 3 * 1024 * 1024 * 1024)).await;
        assert!(matches!(event, TerminalEvent::WriteFailure { .. }));
    });
}

#[test]
fn a_phone_that_never_opened_a_browsing_scope_cannot_write() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        let event = ask(&mut phone, begin("/C:/Users/me/x.txt", 1)).await;
        assert!(matches!(event, TerminalEvent::Failed { .. }), "{event:?}");
        assert!(harness.disk.with(|disk| disk.contents("C:\\Users\\me\\x.txt")).is_none());
    });
}

#[test]
fn a_new_folder_a_rename_and_a_delete_are_each_confirmed() {
    run(async {
        let harness = harness();
        let mut phone = browsing_phone(&harness).await;
        let change = |operation| TerminalRequest::ChangeFile { session_id: SCOPE.to_owned(), operation };

        let made = ask(&mut phone, change(RemoteFileOperation::Create { path: "/C:/Users/me/Docs".to_owned(), kind: RemoteEntryKind::Folder })).await;
        assert!(matches!(made, TerminalEvent::FileOperationDone { .. }), "{made:?}");

        let renamed = ask(&mut phone, change(RemoteFileOperation::Rename { path: "/C:/Users/me/Docs".to_owned(), to: "Papers".to_owned() })).await;
        assert!(matches!(renamed, TerminalEvent::FileOperationDone { .. }), "{renamed:?}");
        assert!(harness.disk.with(|disk| disk.is_folder("C:\\Users\\me\\Papers")));

        let deleted = ask(&mut phone, change(RemoteFileOperation::Delete { path: "/C:/Users/me/Papers".to_owned() })).await;
        let TerminalEvent::FileOperationDone { note, .. } = deleted else { panic!("done, got {deleted:?}") };
        assert!(note.contains("Recycle Bin"));
        assert_eq!(harness.disk.with(|disk| disk.recycled().len()), 1);
    });
}

#[test]
fn deleting_the_users_own_folder_is_refused() {
    run(async {
        let harness = harness();
        let mut phone = browsing_phone(&harness).await;
        let event = ask(
            &mut phone,
            TerminalRequest::ChangeFile {
                session_id: SCOPE.to_owned(),
                operation: RemoteFileOperation::Delete { path: "/C:/Users/me".to_owned() },
            },
        )
        .await;
        assert!(matches!(event, TerminalEvent::FileOperationFailure { .. }));
        assert!(harness.disk.with(|disk| disk.recycled().is_empty()));
    });
}
