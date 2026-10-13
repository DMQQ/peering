//! A phone asking for a folder as one file, over a paired connection.

mod support;

use peering_wire::framing::MessageKind;
use peering_wire::terminal::{TerminalEvent, TerminalRequest};
use support::*;

const SCOPE: &str = "browse-1";

async fn ask(phone: &mut Phone, request: TerminalRequest) -> TerminalEvent {
    phone.send_json(MessageKind::TerminalRequest, &request).await;
    decode_json(&phone.next_of(MessageKind::TerminalEvent).await)
}

async fn browsing_phone(harness: &Harness) -> Phone {
    let mut phone = paired_phone(&harness.runtime).await;
    phone.send_json(MessageKind::TerminalRequest, &TerminalRequest::StartBrowser { id: SCOPE.to_owned() }).await;
    phone
}

#[test]
fn a_folder_is_zipped_and_announced_with_its_size() {
    run(async {
        let harness = harness();
        let mut phone = browsing_phone(&harness).await;
        let event = ask(&mut phone, TerminalRequest::ArchiveFolder { session_id: SCOPE.to_owned(), path: "/C:/Users/me".to_owned() }).await;
        let TerminalEvent::ArchiveReady { session_id, folder, archive_path, total_bytes } = event else {
            panic!("an archive is ready, got {event:?}");
        };
        assert_eq!((session_id.as_str(), folder.as_str()), (SCOPE, "/C:/Users/me"));
        assert!(archive_path.ends_with("/me.zip"), "{archive_path}");
        assert!(total_bytes > 22);
    });
}

#[test]
fn a_path_that_is_not_a_folder_is_a_transfer_failure_the_phone_can_show() {
    run(async {
        let harness = harness();
        let mut phone = browsing_phone(&harness).await;
        let event = ask(&mut phone, TerminalRequest::ArchiveFolder { session_id: SCOPE.to_owned(), path: "/C:/Users/me/notes.txt".to_owned() }).await;
        let TerminalEvent::TransferFailure { path, message, .. } = event else {
            panic!("a failure, got {event:?}");
        };
        assert_eq!((path.as_str(), message.as_str()), ("/C:/Users/me/notes.txt", "That is not a folder."));
    });
}

#[test]
fn a_session_that_is_not_the_phones_may_not_zip_anything() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        let event = ask(&mut phone, TerminalRequest::ArchiveFolder { session_id: "someone-elses".to_owned(), path: "/C:/Users/me".to_owned() }).await;
        assert!(!matches!(event, TerminalEvent::ArchiveReady { .. }));
    });
}
