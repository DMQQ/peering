//! Claude Code hooks from the setting to the phone's answer: the setting installs them, a permission request becomes a push, and
//! the phone's Allow reaches the hook that is waiting.

mod support;

use std::fs;
use std::path::PathBuf;
use std::time::Duration;

use peering_host::hooks::installer::HookFiles;
use peering_host::runtime::RuntimeCommand;
use peering_wire::agent::{AgentApprovalDecision, AgentRequest};
use peering_wire::framing::MessageKind;
use peering_wire::relay_messages::RelayClientMessage;
use peering_wire::terminal::TerminalRequest;
use support::*;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::task::spawn_local;

const PERMISSION: &str = r#"{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"C:\\app","tool_name":"Bash","tool_input":{"command":"npm test"}}"#;

fn folder(name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!("peering-hooks-{name}-{}", std::process::id()));
    drop(fs::remove_dir_all(&path));
    fs::create_dir_all(&path).expect("a temporary folder");
    path
}

async fn eventually(mut check: impl FnMut() -> bool) {
    for _ in 0..200 {
        if check() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("the host reached the expected state");
}

/// The port and the token the hook script was written with.
fn address_in(script: &str) -> (u16, String) {
    let port_text = script.split("http://127.0.0.1:").nth(1).and_then(|rest| rest.split("/hook").next()).expect("the script names a port");
    let token = script.split("X-Peering-Token: ").nth(1).and_then(|rest| rest.split('"').next()).or_else(|| {
        script.split("x-peering-token: ").nth(1).and_then(|rest| rest.split('"').next())
    });
    (port_text.parse().expect("a port"), token.expect("the script carries the token").to_owned())
}

async fn post_hook(port: u16, token: String) -> String {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).await.expect("the hook server listens");
    let request = format!(
        "POST /hook HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Peering-Token: {token}\r\nContent-Length: {}\r\n\r\n{PERMISSION}",
        PERMISSION.len()
    );
    stream.write_all(request.as_bytes()).await.expect("writes");
    let mut response = String::new();
    stream.read_to_string(&mut response).await.expect("reads");
    response
}

#[test]
fn turning_hooks_on_installs_them_and_an_allow_from_the_phone_reaches_the_waiting_hook() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        phone.send_json(MessageKind::TerminalRequest, &TerminalRequest::RegisterPushToken { token: vec![0xAB; 8] }).await;
        phone.sync().await;

        let home = folder("home");
        let support = folder("support");
        let files = HookFiles::new(&home, &support);
        harness.runtime.start_pump();
        harness.runtime.start_hooks(files.clone());
        assert!(!files.is_installed());
        assert!(harness.runtime.handle().send(RuntimeCommand::SetTerminalHooks(true)));
        eventually(|| files.is_installed()).await;

        let script = fs::read_to_string(support.join("peering-hook.cmd")).expect("the script is written");
        let (port, token) = address_in(&script);
        let waiting = spawn_local(post_hook(port, token));

        let mut approval_id = None;
        eventually(|| {
            if let Some(RelayClientMessage::NotifyDevice { approval_id: id, device_token, .. }) = harness.runtime.waiting_notification() {
                assert_eq!(device_token, hex::encode([0xAB; 8]));
                approval_id = id;
            }
            approval_id.is_some()
        })
        .await;

        let request = AgentRequest::Approval {
            session_id: "s1".to_owned(),
            approval_id: approval_id.expect("an approval id"),
            decision: AgentApprovalDecision::Allow {},
        };
        phone.send_json(MessageKind::AgentRequest, &request).await;
        let response = waiting.await.expect("the hook request finishes");
        assert!(response.starts_with("HTTP/1.1 200 OK"), "{response}");
        assert!(response.contains(r#""behavior":"allow""#), "{response}");
        drop(fs::remove_dir_all(&home));
        drop(fs::remove_dir_all(&support));
    });
}

#[test]
fn turning_hooks_off_takes_them_out_of_claude_code() {
    run(async {
        let harness = harness();
        let home = folder("off-home");
        let support = folder("off-support");
        let files = HookFiles::new(&home, &support);
        harness.runtime.start_pump();
        harness.runtime.start_hooks(files.clone());
        harness.runtime.handle().send(RuntimeCommand::SetTerminalHooks(true));
        eventually(|| files.is_installed()).await;
        harness.runtime.handle().send(RuntimeCommand::SetTerminalHooks(false));
        eventually(|| !files.is_installed()).await;
        assert!(!support.join("peering-hook.cmd").exists(), "the script goes with them");
        drop(fs::remove_dir_all(&home));
        drop(fs::remove_dir_all(&support));
    });
}

#[test]
fn hooks_stay_off_until_the_person_turns_them_on() {
    run(async {
        let harness = harness();
        let files = HookFiles::new(&folder("idle-home"), &folder("idle-support"));
        harness.runtime.start_pump();
        harness.runtime.start_hooks(files.clone());
        tokio::time::sleep(Duration::from_millis(600)).await;
        assert!(!files.is_installed());
    });
}

#[test]
fn hooks_that_cannot_be_installed_are_switched_off_and_reported() {
    run(async {
        let harness = harness();
        let home = folder("broken-home");
        fs::create_dir_all(home.join(".claude")).expect("a folder");
        fs::write(home.join(".claude").join("settings.json"), "not json").expect("a file");
        let files = HookFiles::new(&home, &folder("broken-support"));
        harness.runtime.start_pump();
        harness.runtime.start_hooks(files.clone());
        harness.runtime.handle().send(RuntimeCommand::SetTerminalHooks(true));
        eventually(|| harness.runtime.snapshot().problems.iter().any(|problem| problem.contains("Claude Code hooks"))).await;
        assert!(!harness.runtime.snapshot().terminal_hooks, "the setting does not claim hooks that are not there");
        assert_eq!(fs::read_to_string(home.join(".claude").join("settings.json")).expect("still there"), "not json");
    });
}
