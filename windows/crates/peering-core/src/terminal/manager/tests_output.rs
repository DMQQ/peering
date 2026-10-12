use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use peering_wire::terminal::{TerminalAttentionKind, TerminalEvent, TerminalRequest};

use super::tests::{create, events, input, rig, ALICE, BOB};
use super::*;

fn outputs(poll: &Poll) -> Vec<&[u8]> {
    poll.events
        .iter()
        .filter_map(|outbound| match &outbound.event {
            TerminalEvent::Output { data, .. } => Some(data.as_slice()),
            _ => None,
        })
        .collect()
}

#[test]
fn everything_a_shell_printed_in_one_poll_is_one_event() {
    let mut rig = rig();
    create(&mut rig, ALICE);
    for line in ["one\r\n", "two\r\n", "three\r\n"] {
        rig.shells.shell(0).print(line.as_bytes());
    }
    assert_eq!(outputs(&rig.manager.poll()), [b"one\r\ntwo\r\nthree\r\n".as_slice()]);
    assert!(rig.manager.poll().events.is_empty());
}

#[test]
fn a_burst_of_output_is_split_into_events_of_at_most_64_kib() {
    let mut rig = rig();
    create(&mut rig, ALICE);
    rig.shells.shell(0).print(&vec![b'x'; 150 * 1024]);
    let poll = rig.manager.poll();
    let sizes: Vec<usize> = outputs(&poll).iter().map(|data| data.len()).collect();
    assert_eq!(sizes, [64 * 1024, 64 * 1024, 22 * 1024]);
}

#[test]
fn a_reconnecting_client_is_sent_its_snapshot_then_the_history() {
    let mut rig = rig();
    let id = create(&mut rig, ALICE);
    rig.shells.shell(0).print(b"hello\r\n");
    rig.manager.poll();
    rig.manager.disconnect(ALICE);
    rig.shells.shell(0).print(b"while away\r\n");
    assert!(rig.manager.poll().events.is_empty(), "nobody is listening");
    let replay = events(rig.manager.handle(ALICE, &TerminalRequest::List {}));
    assert!(matches!(replay[0], TerminalEvent::Snapshot { .. }));
    assert_eq!(replay[1..], [TerminalEvent::Output { session_id: id, data: b"hello\r\nwhile away\r\n".to_vec() }]);
}

#[test]
fn the_history_is_bounded_and_keeps_the_newest_bytes() {
    let mut rig = rig();
    create(&mut rig, ALICE);
    rig.shells.shell(0).print(&vec![b'a'; 600 * 1024]);
    rig.shells.shell(0).print(&vec![b'b'; 100 * 1024]);
    rig.manager.poll();
    let replay = events(rig.manager.handle(ALICE, &TerminalRequest::List {}));
    let history: Vec<u8> = replay
        .iter()
        .flat_map(|event| match event {
            TerminalEvent::Output { data, .. } => data.clone(),
            _ => Vec::new(),
        })
        .collect();
    assert!(history.len() <= 512 * 1024 + 64 * 1024, "kept {} bytes", history.len());
    assert!(history.ends_with(&[b'b'; 100 * 1024]));
}

#[test]
fn history_is_replayed_only_to_the_owner() {
    let mut rig = rig();
    create(&mut rig, ALICE);
    rig.shells.shell(0).print(b"secret\r\n");
    rig.manager.poll();
    let theirs = events(rig.manager.handle(BOB, &TerminalRequest::List {}));
    assert_eq!(theirs, vec![TerminalEvent::Snapshot { terminals: Vec::new() }]);
}

#[test]
fn output_goes_only_to_the_client_that_owns_the_terminal() {
    let mut rig = rig();
    create(&mut rig, ALICE);
    rig.manager.handle(BOB, &TerminalRequest::List {});
    rig.shells.shell(0).print(b"x");
    let poll = rig.manager.poll();
    assert!(poll.events.iter().all(|outbound| outbound.client_id == ALICE));
}

#[test]
fn a_shell_that_ends_reports_its_status_after_its_last_output() {
    let mut rig = rig();
    let id = create(&mut rig, ALICE);
    rig.shells.shell(0).print(b"bye\r\n");
    rig.shells.shell(0).exit(3);
    let poll = rig.manager.poll();
    let kinds: Vec<&TerminalEvent> = poll.events.iter().map(|outbound| &outbound.event).collect();
    assert_eq!(kinds[0], &TerminalEvent::Output { session_id: id.clone(), data: b"bye\r\n".to_vec() });
    assert_eq!(kinds[1], &TerminalEvent::Exited { session_id: id.clone(), status: 3 });
    assert!(rig.manager.poll().events.is_empty(), "an exit is reported once");
    assert!(input(&mut rig, ALICE, &id, "a")[0] != TerminalEvent::Closed { session_id: id.clone() });
    let listed = events(rig.manager.handle(ALICE, &TerminalRequest::List {}));
    let TerminalEvent::Snapshot { terminals } = &listed[0] else { panic!("a snapshot comes first") };
    assert!(!terminals[0].is_running);
}

#[test]
fn a_prompt_in_the_output_raises_attention_once() {
    let mut rig = rig();
    let id = create(&mut rig, ALICE);
    rig.shells.shell(0).print(b"Continue? [y/N] ");
    let poll = rig.manager.poll();
    let expected = TerminalEvent::Attention {
        session_id: id.clone(),
        kind: TerminalAttentionKind::Confirmation,
        message: "Continue? [y/N]".to_owned(),
    };
    assert_eq!(poll.events.last().map(|outbound| &outbound.event), Some(&expected));
    rig.shells.shell(0).print(b"Continue? [y/N] ");
    assert!(!rig.manager.poll().events.iter().any(|outbound| matches!(outbound.event, TerminalEvent::Attention { .. })));
    input(&mut rig, ALICE, &id, "y\r");
    rig.manager.poll();
    rig.shells.shell(0).print(b"Password: ");
    let poll = rig.manager.poll();
    assert!(matches!(
        poll.events.last().map(|outbound| &outbound.event),
        Some(TerminalEvent::Attention { kind: TerminalAttentionKind::Password, .. })
    ));
}

#[test]
fn a_finished_command_is_reported_with_its_command_and_duration() {
    let mut rig = rig();
    let id = create(&mut rig, ALICE);
    let marker = format!("\x1b]9999;65500;1;{}\x07", STANDARD.encode("cargo build"));
    rig.shells.shell(0).print(marker.as_bytes());
    let poll = rig.manager.poll();
    let expected = TerminalEvent::CommandFinished {
        session_id: id,
        command: Some("cargo build".to_owned()),
        duration: 65.5,
        exit_status: 1,
    };
    assert_eq!(poll.events.last().map(|outbound| &outbound.event), Some(&expected));
}

#[test]
fn a_prompt_while_nobody_is_connected_is_pushed_to_the_registered_phone() {
    let mut rig = rig();
    let id = create(&mut rig, ALICE);
    rig.manager.handle(ALICE, &TerminalRequest::RegisterPushToken { token: vec![0xBE, 0xEF] });
    rig.manager.disconnect(ALICE);
    rig.shells.shell(0).print(b"[sudo] password for me: ");
    let poll = rig.manager.poll();
    assert!(poll.events.is_empty());
    assert_eq!(poll.pushes, vec![PushAlert {
        token: "beef".to_owned(),
        title: "Terminal needs you".to_owned(),
        message: "[sudo] password for me:".to_owned(),
    }]);
    let marker = format!("\x1b]9999;7000;0;{}\x07", STANDARD.encode("make"));
    rig.shells.shell(0).print(marker.as_bytes());
    let pushes = rig.manager.poll().pushes;
    assert_eq!(pushes[0].title, "Terminal finished");
    assert_eq!(pushes[0].message, "\u{201C}make\u{201D} finished after 7s.");
    assert!(!id.is_empty());
}

#[test]
fn nothing_is_pushed_to_a_connected_phone_or_to_one_without_a_token() {
    let mut rig = rig();
    create(&mut rig, ALICE);
    rig.manager.handle(ALICE, &TerminalRequest::RegisterPushToken { token: vec![1] });
    rig.shells.shell(0).print(b"Password: ");
    assert!(rig.manager.poll().pushes.is_empty());
    rig.manager.disconnect(ALICE);
    rig.manager.handle(ALICE, &TerminalRequest::RegisterPushToken { token: Vec::new() });
    rig.manager.disconnect(ALICE);
    rig.shells.shell(0).print(b"Password: ");
    assert!(rig.manager.poll().pushes.is_empty());
}

#[test]
fn dropping_the_manager_ends_the_running_shells() {
    let rig = rig();
    let shells = rig.shells.clone();
    let mut rig = rig;
    create(&mut rig, ALICE);
    drop(rig);
    assert!(shells.shell(0).state().killed);
}
