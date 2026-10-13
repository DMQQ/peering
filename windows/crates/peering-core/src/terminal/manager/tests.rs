use std::sync::Arc;

use peering_wire::terminal::{TerminalEvent, TerminalRequest};

use super::*;
use crate::fakes::clock::FakeClock;
use crate::fakes::secret_store::InMemorySecretStore;
use crate::push_tokens::PushTokenStore;
use crate::terminal::fake::FakeSpawner;
use crate::terminal::shell::{Shell, ShellKind};

pub(super) const ALICE: &str = "alice";
pub(super) const BOB: &str = "bob";

struct InstalledAgents(Vec<&'static str>);

impl AgentLocator for InstalledAgents {
    fn installed(&self, names: &[&str]) -> Vec<String> {
        names.iter().filter(|name| self.0.contains(name)).map(|name| (*name).to_owned()).collect()
    }
}

pub(super) struct Rig {
    pub(super) manager: TerminalSessionManager,
    pub(super) shells: FakeSpawner,
    pub(super) tokens: Arc<PushTokenStore<InMemorySecretStore>>,
}

pub(super) fn rig() -> Rig {
    let shells = FakeSpawner::default();
    let tokens = Arc::new(PushTokenStore::open(InMemorySecretStore::default()).expect("the store opens"));
    let mut next = 0;
    let deps = TerminalDeps {
        spawner: Box::new(shells.clone()),
        tokens: Box::new(tokens.clone()),
        agents: Box::new(InstalledAgents(vec!["claude", "aider"])),
        clock: Arc::new(FakeClock::new(0.0, 978_307_200 + 1_000)),
        new_id: Box::new(move || {
            next += 1;
            format!("00000000-0000-4000-8000-{next:012X}")
        }),
    };
    let shell = Shell { kind: ShellKind::Cmd, program: "cmd.exe".to_owned(), arguments: Vec::new() };
    let config = TerminalConfig { shells: vec![shell], directory: "C:\\Users\\me".to_owned(), environment: Vec::new() };
    Rig { manager: TerminalSessionManager::new(deps, config), shells, tokens }
}

pub(super) fn events(outcome: Outcome) -> Vec<TerminalEvent> {
    match outcome {
        Outcome::Events(events) => events,
        Outcome::Browse => panic!("the request was meant for the file service"),
    }
}

pub(super) fn create(rig: &mut Rig, client: &str) -> String {
    match events(rig.manager.handle(client, &TerminalRequest::Create {})).as_slice() {
        [TerminalEvent::Created { terminal }] => terminal.id.clone(),
        other => panic!("expected one created event, got {other:?}"),
    }
}

pub(super) fn input(rig: &mut Rig, client: &str, id: &str, text: &str) -> Vec<TerminalEvent> {
    let request = TerminalRequest::Input { session_id: id.to_owned(), data: text.as_bytes().to_vec() };
    events(rig.manager.handle(client, &request))
}

fn failure_message(events: &[TerminalEvent]) -> &str {
    match events {
        [TerminalEvent::Failed { message, .. }] => message,
        other => panic!("expected one failure, got {other:?}"),
    }
}

#[test]
fn a_created_terminal_starts_in_the_home_folder_at_100_by_30() {
    let mut rig = rig();
    let id = create(&mut rig, ALICE);
    let shell = rig.shells.shell(0);
    let state = shell.state();
    assert_eq!(state.directory, "C:\\Users\\me");
    assert_eq!((state.columns, state.rows), (100, 30));
    drop(state);
    let listed = events(rig.manager.handle(ALICE, &TerminalRequest::List {}));
    let TerminalEvent::Snapshot { terminals } = &listed[0] else { panic!("a snapshot comes first") };
    assert_eq!(terminals[0].id, id);
    assert_eq!(terminals[0].name, "Terminal 1");
    assert_eq!(terminals[0].created_at, Some(1_000.0));
    assert_eq!((terminals[0].columns, terminals[0].rows), (Some(100), Some(30)));
}

#[test]
fn input_reaches_the_shell_and_its_echo_comes_back_as_output() {
    let mut rig = rig();
    let id = create(&mut rig, ALICE);
    assert!(input(&mut rig, ALICE, &id, "dir\r").is_empty());
    assert_eq!(rig.shells.shell(0).state().written, b"dir\r");
    let poll = rig.manager.poll();
    assert_eq!(poll.events, vec![Outbound {
        client_id: ALICE.to_owned(),
        event: TerminalEvent::Output { session_id: id, data: b"dir\r".to_vec() },
    }]);
}

#[test]
fn oversized_input_and_input_to_a_missing_terminal_fail() {
    let mut rig = rig();
    let id = create(&mut rig, ALICE);
    let big = "x".repeat(MAXIMUM_INPUT_BYTES + 1);
    assert_eq!(failure_message(&input(&mut rig, ALICE, &id, &big)), "Terminal input was too large.");
    assert_eq!(failure_message(&input(&mut rig, ALICE, "nope", "a")), GONE);
    rig.shells.shell(0).state().fail_writes = true;
    assert_eq!(failure_message(&input(&mut rig, ALICE, &id, "a")), "Could not write to the terminal.");
}

#[test]
fn resizing_changes_the_shell_and_what_the_next_listing_reports() {
    let mut rig = rig();
    let id = create(&mut rig, ALICE);
    let resize = |columns, rows| TerminalRequest::Resize { session_id: id.clone(), columns, rows };
    rig.manager.handle(ALICE, &resize(132, 43));
    rig.manager.handle(ALICE, &resize(0, 10));
    let (columns, rows) = {
        let shell = rig.shells.shell(0);
        let state = shell.state();
        (state.columns, state.rows)
    };
    assert_eq!((columns, rows), (132, 43));
    let listed = events(rig.manager.handle(ALICE, &TerminalRequest::List {}));
    let TerminalEvent::Snapshot { terminals } = &listed[0] else { panic!("a snapshot comes first") };
    assert_eq!((terminals[0].columns, terminals[0].rows), (Some(132), Some(43)));
}

#[test]
fn closing_ends_the_shell_and_forgets_the_terminal() {
    let mut rig = rig();
    let id = create(&mut rig, ALICE);
    let closed = events(rig.manager.handle(ALICE, &TerminalRequest::Close { session_id: id.clone() }));
    assert_eq!(closed, vec![TerminalEvent::Closed { session_id: id }]);
    assert!(rig.shells.shell(0).state().killed);
    let listed = events(rig.manager.handle(ALICE, &TerminalRequest::List {}));
    assert_eq!(listed, vec![TerminalEvent::Snapshot { terminals: Vec::new() }]);
}

#[test]
fn a_client_cannot_touch_another_clients_terminal() {
    let mut rig = rig();
    let id = create(&mut rig, ALICE);
    assert_eq!(failure_message(&input(&mut rig, BOB, &id, "x")), GONE);
    assert!(events(rig.manager.handle(BOB, &TerminalRequest::Close { session_id: id.clone() })).is_empty());
    let rename = TerminalRequest::Rename { session_id: id.clone(), name: "mine".to_owned() };
    assert!(events(rig.manager.handle(BOB, &rename)).is_empty());
    assert_eq!(events(rig.manager.handle(BOB, &TerminalRequest::List {})), vec![TerminalEvent::Snapshot { terminals: Vec::new() }]);
    assert!(!rig.shells.shell(0).state().killed);
    assert_eq!(failure_message(&events(rig.manager.handle(BOB, &TerminalRequest::ListDirectory { session_id: id, path: None }))), GONE);
}

#[test]
fn a_client_may_hold_ten_terminals_and_no_more() {
    let mut rig = rig();
    for _ in 0..MAXIMUM_SESSIONS_PER_CLIENT {
        create(&mut rig, ALICE);
    }
    let eleventh = events(rig.manager.handle(ALICE, &TerminalRequest::Create {}));
    assert_eq!(failure_message(&eleventh), "Terminal session limit reached.");
    create(&mut rig, BOB);
}

#[test]
fn a_shell_that_cannot_start_is_reported() {
    let mut rig = rig();
    rig.shells.refuse_to_start();
    let reply = events(rig.manager.handle(ALICE, &TerminalRequest::Create {}));
    assert!(failure_message(&reply).starts_with("Could not start the shell"));
}

#[test]
fn agents_lists_the_installed_ones_in_the_known_order() {
    let mut rig = rig();
    let reply = events(rig.manager.handle(ALICE, &TerminalRequest::Agents {}));
    assert_eq!(reply, vec![TerminalEvent::Agents { installed: vec!["claude".to_owned(), "aider".to_owned()] }]);
}

#[test]
fn a_request_without_a_client_identity_is_refused() {
    let mut rig = rig();
    let reply = events(rig.manager.handle("", &TerminalRequest::Create {}));
    assert_eq!(failure_message(&reply), "The authenticated device has no identity.");
    assert_eq!(rig.shells.started(), 0);
}

#[test]
fn a_push_token_is_stored_and_an_empty_one_forgets_it() {
    let mut rig = rig();
    let register = |bytes: &[u8]| TerminalRequest::RegisterPushToken { token: bytes.to_vec() };
    assert!(events(rig.manager.handle(ALICE, &register(&[0xAB, 0x01]))).is_empty());
    assert_eq!(rig.tokens.token_for(ALICE).as_deref(), Some("ab01"));
    rig.manager.handle(ALICE, &register(&[]));
    assert_eq!(rig.tokens.token_for(ALICE), None);
}

#[test]
fn file_requests_are_allowed_for_a_live_terminal_or_a_browsing_scope_and_nothing_else() {
    let mut rig = rig();
    let id = create(&mut rig, ALICE);
    let list = |id: &str| TerminalRequest::ListDirectory { session_id: id.to_owned(), path: None };
    assert_eq!(rig.manager.handle(ALICE, &list(&id)), Outcome::Browse);
    assert_eq!(failure_message(&events(rig.manager.handle(ALICE, &list("scope")))), GONE);
    rig.manager.handle(ALICE, &TerminalRequest::StartBrowser { id: "scope".to_owned() });
    assert_eq!(rig.manager.handle(ALICE, &list("scope")), Outcome::Browse);
    assert_eq!(failure_message(&events(rig.manager.handle(BOB, &list("scope")))), GONE);
    rig.manager.disconnect(ALICE);
    assert_eq!(failure_message(&events(rig.manager.handle(ALICE, &list("scope")))), GONE);
}

#[test]
fn a_client_may_open_four_browsing_scopes() {
    let mut rig = rig();
    for number in 0..=MAXIMUM_BROWSERS_PER_CLIENT {
        rig.manager.handle(ALICE, &TerminalRequest::StartBrowser { id: format!("scope-{number}") });
    }
    let list = |number: usize| TerminalRequest::ListDirectory { session_id: format!("scope-{number}"), path: None };
    assert_eq!(rig.manager.handle(ALICE, &list(MAXIMUM_BROWSERS_PER_CLIENT - 1)), Outcome::Browse);
    assert!(matches!(rig.manager.handle(ALICE, &list(MAXIMUM_BROWSERS_PER_CLIENT)), Outcome::Events(_)));
}

#[test]
fn terminals_are_named_with_the_lowest_free_number() {
    let mut rig = rig();
    let first = create(&mut rig, ALICE);
    let second = create(&mut rig, ALICE);
    rig.manager.handle(ALICE, &TerminalRequest::Close { session_id: first });
    create(&mut rig, ALICE);
    let listed = events(rig.manager.handle(ALICE, &TerminalRequest::List {}));
    let TerminalEvent::Snapshot { terminals } = &listed[0] else { panic!("a snapshot comes first") };
    let names: Vec<&str> = terminals.iter().map(|terminal| terminal.name.as_str()).collect();
    assert_eq!(names, ["Terminal 1", "Terminal 2"]);
    assert!(terminals.iter().any(|terminal| terminal.id == second));
}

#[test]
fn a_manual_name_wins_over_a_command_title_and_clearing_it_falls_back() {
    let mut rig = rig();
    let id = create(&mut rig, ALICE);
    let rename = |name: &str| TerminalRequest::Rename { session_id: id.clone(), name: name.to_owned() };
    let retitle = |command: &str| TerminalRequest::Retitle { session_id: id.clone(), command: command.to_owned() };
    let name_of = |events: Vec<TerminalEvent>| match events.as_slice() {
        [TerminalEvent::Renamed { terminal }] => Some(terminal.name.clone()),
        [] => None,
        other => panic!("unexpected {other:?}"),
    };
    assert_eq!(name_of(events(rig.manager.handle(ALICE, &retitle("npm test")))), Some("npm test".to_owned()));
    assert_eq!(name_of(events(rig.manager.handle(ALICE, &rename("  build box \n")))), Some("build box".to_owned()));
    assert_eq!(name_of(events(rig.manager.handle(ALICE, &retitle("cargo run")))), None);
    assert_eq!(name_of(events(rig.manager.handle(ALICE, &rename("")))), Some("cargo run".to_owned()));
    assert_eq!(name_of(events(rig.manager.handle(ALICE, &retitle("   ")))), None);
}

#[test]
fn a_name_loses_control_characters_and_is_cut_at_forty_characters() {
    let mut rig = rig();
    let id = create(&mut rig, ALICE);
    let name = format!("a\u{7}b{}", "c".repeat(60));
    let reply = events(rig.manager.handle(ALICE, &TerminalRequest::Rename { session_id: id, name }));
    let [TerminalEvent::Renamed { terminal }] = reply.as_slice() else { panic!("renamed") };
    assert_eq!(terminal.name.chars().count(), 40);
    assert!(terminal.name.starts_with("abcc"));
}
