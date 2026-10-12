use std::sync::Arc;

use super::*;
use crate::session::deps::PairedDevice;
use crate::session::test_support::MemoryPins;

const HOST_ID: &str = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";

fn service(pins: Arc<MemoryPins>) -> PairingService {
    PairingService::new(HOST_ID, pins)
}

fn device(id: &str, name: &str, last_seen_unix: u64) -> PairedDevice {
    PairedDevice { id: id.to_owned(), name: name.to_owned(), public_key: vec![0x04; 65], last_seen_unix }
}

fn code_event() -> HostEvent {
    HostEvent::PairingCode {
        code: "365357".to_owned(),
        secret: vec![0x0a, 0xff],
        client_name: "Pixel 9".to_owned(),
        via_relay: true,
    }
}

#[test]
fn a_pairing_code_event_opens_the_offer_with_its_qr_strings() {
    let mut pairing = service(Arc::new(MemoryPins::default()));
    pairing.apply_event(1, &code_event(), 0.0);

    let offer = pairing.offer().expect("an offer is shown");
    assert_eq!(offer.code, "365357");
    assert_eq!(offer.secret_hex, "0aff");
    assert_eq!(offer.client_name, "Pixel 9");
    assert!(offer.via_relay);
    assert_eq!(offer.code_link, "peering://pair?code=365357&secret=0aff");
    assert_eq!(offer.host_link, "https://getpeering.app/mac?id=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE");
}

#[test]
fn a_finished_pairing_closes_the_offer() {
    let mut pairing = service(Arc::new(MemoryPins::default()));
    pairing.apply_event(1, &code_event(), 0.0);
    pairing.apply_event(1, &HostEvent::PairingCompleted { client_name: "Pixel 9".to_owned(), accepted: true }, 0.0);
    assert_eq!(pairing.offer(), None);
}

#[test]
fn a_client_connecting_leaves_the_offer_alone() {
    let mut pairing = service(Arc::new(MemoryPins::default()));
    pairing.apply_event(1, &code_event(), 0.0);
    pairing.apply_event(1, &HostEvent::ClientConnected {
        client_id: "c".to_owned(),
        client_name: "Other".to_owned(),
        via_relay: false,
    }, 0.0);
    assert_eq!(pairing.offer().map(|offer| offer.code.as_str()), Some("365357"));
}

#[test]
fn approving_returns_the_session_and_removes_the_request() {
    let mut pairing = service(Arc::new(MemoryPins::default()));
    let id = pairing.request_approval(7, "Pixel 9").expect("room");
    assert_eq!(pairing.pending_approvals().len(), 1);
    assert_eq!(pairing.pending_approvals()[0].client_name, "Pixel 9");

    assert_eq!(pairing.approve(id), Some(ApprovalDecision { session: 7, approved: true }));
    assert!(pairing.pending_approvals().is_empty());
    assert_eq!(pairing.approve(id), None);
}

#[test]
fn declining_returns_the_session_as_refused() {
    let mut pairing = service(Arc::new(MemoryPins::default()));
    let id = pairing.request_approval(3, "Pixel 9").expect("room");
    assert_eq!(pairing.decline(id), Some(ApprovalDecision { session: 3, approved: false }));
    assert!(pairing.pending_approvals().is_empty());
}

#[test]
fn an_unknown_approval_id_changes_nothing() {
    let mut pairing = service(Arc::new(MemoryPins::default()));
    let kept = pairing.request_approval(1, "Pixel 9").expect("room");
    assert_eq!(pairing.approve(kept + 100), None);
    assert_eq!(pairing.pending_approvals().len(), 1);
}

#[test]
fn approvals_keep_arrival_order_and_distinct_ids() {
    let mut pairing = service(Arc::new(MemoryPins::default()));
    let first = pairing.request_approval(1, "First").expect("room");
    let second = pairing.request_approval(2, "Second").expect("room");
    assert_ne!(first, second);
    let names: Vec<&str> = pairing.pending_approvals().iter().map(|a| a.client_name.as_str()).collect();
    assert_eq!(names, ["First", "Second"]);
}

#[test]
fn forgetting_a_session_drops_only_its_approvals() {
    let mut pairing = service(Arc::new(MemoryPins::default()));
    pairing.request_approval(1, "Gone").expect("room");
    let kept = pairing.request_approval(2, "Still here").expect("room");
    pairing.forget_session(1);
    assert_eq!(pairing.pending_approvals().len(), 1);
    assert_eq!(pairing.approve(kept), Some(ApprovalDecision { session: 2, approved: true }));
}

#[test]
fn paired_devices_list_id_name_and_last_seen() {
    let pins = Arc::new(MemoryPins::with_device(device("B-DEVICE", "Laptop", 20)));
    assert!(pins.record(&device("A-DEVICE", "Pixel 9", 10)));
    let pairing = service(pins);
    assert_eq!(
        pairing.paired_devices(),
        vec![
            PairedDeviceEntry { id: "A-DEVICE".to_owned(), name: "Pixel 9".to_owned(), last_seen_unix: 10 },
            PairedDeviceEntry { id: "B-DEVICE".to_owned(), name: "Laptop".to_owned(), last_seen_unix: 20 },
        ]
    );
}

#[test]
fn revoking_removes_the_pin_and_reports_it() {
    let pins = Arc::new(MemoryPins::with_device(device("A-DEVICE", "Pixel 9", 10)));
    let pairing = service(pins.clone());
    assert!(pairing.revoke("A-DEVICE"));
    assert_eq!(pins.pin_for("A-DEVICE"), None);
    assert!(pairing.paired_devices().is_empty());
}

#[test]
fn revoking_an_unknown_device_reports_nothing_removed() {
    let pairing = service(Arc::new(MemoryPins::default()));
    assert!(!pairing.revoke("NOBODY"));
}

#[test]
fn a_second_session_cannot_replace_the_offer_of_the_first() {
    let mut pairing = service(Arc::new(MemoryPins::default()));
    pairing.apply_event(1, &code_event(), 0.0);
    let intruder = HostEvent::PairingCode {
        code: "111111".to_owned(),
        secret: vec![1],
        client_name: "Intruder".to_owned(),
        via_relay: false,
    };
    pairing.apply_event(2, &intruder, 0.0);
    assert_eq!(pairing.offer().map(|offer| offer.code.as_str()), Some("365357"));
}

#[test]
fn a_second_session_takes_over_an_offer_that_outlived_its_lifetime() {
    let mut pairing = service(Arc::new(MemoryPins::default()));
    pairing.apply_event(1, &code_event(), 0.0);
    let newer = HostEvent::PairingCode { code: "222222".to_owned(), secret: vec![2], client_name: "Newer".to_owned(), via_relay: false };
    pairing.apply_event(2, &newer, OFFER_LIFETIME_SECONDS);
    assert_eq!(pairing.offer().map(|offer| offer.code.as_str()), Some("365357"), "still inside its lifetime");
    pairing.apply_event(2, &newer, OFFER_LIFETIME_SECONDS + 0.5);
    assert_eq!(pairing.offer().map(|offer| (offer.session, offer.code.as_str())), Some((2, "222222")));
}

#[test]
fn a_session_renewing_its_own_offer_does_not_extend_its_lifetime() {
    let mut pairing = service(Arc::new(MemoryPins::default()));
    pairing.apply_event(1, &code_event(), 0.0);
    pairing.apply_event(1, &code_event(), 100.0);
    let newer = HostEvent::PairingCode { code: "222222".to_owned(), secret: vec![2], client_name: "Newer".to_owned(), via_relay: false };
    pairing.apply_event(2, &newer, 121.0);
    assert_eq!(pairing.offer().map(|offer| offer.session), Some(2));
}

#[test]
fn a_second_session_cannot_close_the_offer_of_the_first() {
    let mut pairing = service(Arc::new(MemoryPins::default()));
    pairing.apply_event(1, &code_event(), 0.0);
    pairing.apply_event(2, &HostEvent::PairingCompleted { client_name: "Other".to_owned(), accepted: false }, 0.0);
    assert!(pairing.offer().is_some());
}

#[test]
fn the_offer_goes_when_its_session_ends_without_finishing() {
    let mut pairing = service(Arc::new(MemoryPins::default()));
    pairing.apply_event(1, &code_event(), 0.0);
    pairing.forget_session(1);
    assert_eq!(pairing.offer(), None);
}

#[test]
fn a_new_pairing_can_start_once_the_old_session_is_gone() {
    let mut pairing = service(Arc::new(MemoryPins::default()));
    pairing.apply_event(1, &code_event(), 0.0);
    pairing.forget_session(1);
    pairing.apply_event(2, &code_event(), 0.0);
    assert_eq!(pairing.offer().map(|offer| offer.session), Some(2));
}

#[test]
fn forgetting_another_session_keeps_the_offer() {
    let mut pairing = service(Arc::new(MemoryPins::default()));
    pairing.apply_event(1, &code_event(), 0.0);
    pairing.forget_session(2);
    assert!(pairing.offer().is_some());
}

#[test]
fn approvals_past_the_cap_are_refused_for_the_asking_session() {
    let mut pairing = service(Arc::new(MemoryPins::default()));
    for session in 0..MAXIMUM_PENDING_APPROVALS as u64 {
        pairing.request_approval(session, "Phone").expect("room");
    }
    assert_eq!(pairing.request_approval(99, "Flood"), Err(ApprovalDecision { session: 99, approved: false }));
    assert_eq!(pairing.pending_approvals().len(), MAXIMUM_PENDING_APPROVALS);
}

#[test]
fn answering_an_approval_makes_room_for_the_next() {
    let mut pairing = service(Arc::new(MemoryPins::default()));
    let first = pairing.request_approval(0, "Phone").expect("room");
    for session in 1..MAXIMUM_PENDING_APPROVALS as u64 {
        pairing.request_approval(session, "Phone").expect("room");
    }
    pairing.decline(first);
    assert!(pairing.request_approval(50, "Next").is_ok());
}
