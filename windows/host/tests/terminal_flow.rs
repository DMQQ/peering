mod support;

use peering_host::runtime::HostRuntime;
use peering_wire::framing::MessageKind;
use peering_wire::terminal::{TerminalAttentionKind, TerminalEvent, TerminalRequest};
use support::*;

async fn ask(phone: &mut Phone, request: &TerminalRequest) {
    phone.send_json(MessageKind::TerminalRequest, request).await;
}

async fn next_event(phone: &mut Phone) -> TerminalEvent {
    decode_json(&phone.next_of(MessageKind::TerminalEvent).await)
}

async fn create_terminal(phone: &mut Phone) -> String {
    ask(phone, &TerminalRequest::Create {}).await;
    match next_event(phone).await {
        TerminalEvent::Created { terminal } => terminal.id,
        other => panic!("expected a created terminal, got {other:?}"),
    }
}

/// Pumps the terminals and returns the next event the phone is sent.
async fn pumped_event(runtime: &HostRuntime, phone: &mut Phone) -> TerminalEvent {
    runtime.pump_terminals();
    next_event(phone).await
}

#[test]
fn the_hello_advertises_the_agent_list_it_serves() {
    run(async {
        let harness = harness();
        let hello = server_hello_of(&harness).await;
        assert_eq!(hello.capabilities.supports_agent_list, Some(true));
        assert_eq!(hello.capabilities.pushes_terminal_alerts_while_connected, None);
    });
}

async fn server_hello_of(harness: &Harness) -> peering_wire::handshake::ServerHello {
    let mut phone = Phone::connect(&harness.runtime, direct_peer());
    phone.send(role_frame(CONTROL_ROLE)).await;
    phone.send(hello()).await;
    server_hello(&phone.next_of(MessageKind::ServerHello).await)
}

#[test]
fn a_created_terminal_echoes_what_the_phone_types() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        let id = create_terminal(&mut phone).await;
        ask(&mut phone, &TerminalRequest::Input { session_id: id.clone(), data: b"dir\r".to_vec() }).await;
        phone.sync().await;
        let event = pumped_event(&harness.runtime, &mut phone).await;
        assert_eq!(event, TerminalEvent::Output { session_id: id, data: b"dir\r".to_vec() });
        assert_eq!(harness.shells.shell(0).state().directory, "C:\\Users\\me");
    });
}

#[test]
fn a_resize_reaches_the_shell() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        let id = create_terminal(&mut phone).await;
        ask(&mut phone, &TerminalRequest::Resize { session_id: id, columns: 90, rows: 25 }).await;
        phone.sync().await;
        let shell = harness.shells.shell(0);
        let state = shell.state();
        assert_eq!((state.columns, state.rows), (90, 25));
    });
}

#[test]
fn a_reconnecting_phone_gets_its_terminal_and_what_it_printed_while_away() {
    run(async {
        let harness = harness();
        let mut first = paired_phone(&harness.runtime).await;
        let id = create_terminal(&mut first).await;
        harness.shells.shell(0).print(b"before\r\n");
        pumped_event(&harness.runtime, &mut first).await;
        drop(first);
        until(|| (harness.runtime.snapshot().connected_clients == 0).then_some(())).await;
        harness.shells.shell(0).print(b"while away\r\n");
        harness.runtime.pump_terminals();

        let mut second = reconnected_phone(&harness.runtime).await;
        ask(&mut second, &TerminalRequest::List {}).await;
        let TerminalEvent::Snapshot { terminals } = next_event(&mut second).await else { panic!("a snapshot first") };
        assert_eq!(terminals.len(), 1);
        assert_eq!(terminals[0].id, id);
        let replay = next_event(&mut second).await;
        assert_eq!(replay, TerminalEvent::Output { session_id: id, data: b"before\r\nwhile away\r\n".to_vec() });
    });
}

#[test]
fn a_prompt_in_the_output_is_reported_to_the_phone() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        let id = create_terminal(&mut phone).await;
        harness.shells.shell(0).print(b"[sudo] password for me: ");
        assert!(matches!(pumped_event(&harness.runtime, &mut phone).await, TerminalEvent::Output { .. }));
        let attention = next_event(&mut phone).await;
        assert_eq!(attention, TerminalEvent::Attention {
            session_id: id,
            kind: TerminalAttentionKind::Password,
            message: "[sudo] password for me:".to_owned(),
        });
    });
}

#[test]
fn an_exited_shell_and_a_closed_terminal_are_reported() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        let id = create_terminal(&mut phone).await;
        harness.shells.shell(0).exit(2);
        let exited = pumped_event(&harness.runtime, &mut phone).await;
        assert_eq!(exited, TerminalEvent::Exited { session_id: id.clone(), status: 2 });
        ask(&mut phone, &TerminalRequest::Close { session_id: id.clone() }).await;
        assert_eq!(next_event(&mut phone).await, TerminalEvent::Closed { session_id: id });
    });
}

#[test]
fn file_requests_need_a_terminal_or_a_browsing_scope() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        let list = |id: &str| TerminalRequest::ListDirectory { session_id: id.to_owned(), path: Some("/C:/Users/me".to_owned()) };
        ask(&mut phone, &list("nobody")).await;
        assert!(matches!(next_event(&mut phone).await, TerminalEvent::Failed { .. }));
        let id = create_terminal(&mut phone).await;
        ask(&mut phone, &list(&id)).await;
        assert!(matches!(next_event(&mut phone).await, TerminalEvent::Directory { .. }));
    });
}

#[test]
fn the_agent_list_is_answered() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        ask(&mut phone, &TerminalRequest::Agents {}).await;
        assert!(matches!(next_event(&mut phone).await, TerminalEvent::Agents { .. }));
    });
}
