//! The decision `tools/deploy-relay.sh` makes after a restart: keep the new binary or roll it back.

#![cfg(unix)]

use std::io::{Read, Write};
use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

fn open_port() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || for _ in listener.incoming() {});
    port
}

fn serve_status(status: u16) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for mut stream in listener.incoming().map_while(Result::ok) {
            let mut buffer = [0u8; 1024];
            let _ = stream.read(&mut buffer);
            let _ = write!(stream, "HTTP/1.1 {status} X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        }
    });
    port
}

fn stubs(name: &str) -> PathBuf {
    let directory = std::env::temp_dir().join(format!("peeringd-deploy-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    std::fs::create_dir_all(&directory).unwrap();
    for (file, body) in [("sleep", "exit 0"), ("timeout", "shift; exec \"$@\"")] {
        let path = directory.join(file);
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    directory
}

/// Whether the deploy would keep the new binary: the exit status of `healthy` as the script runs it.
fn keeps_the_new_binary(web: Option<u16>, signalling: u16, control: u16, name: &str) -> bool {
    let directory = stubs(name);
    let path = format!("{}:{}", directory.display(), std::env::var("PATH").unwrap());
    let url = format!("http://127.0.0.1:{}/healthz", web.unwrap_or_else(free_port));
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("deploy/peeringd-deploy-health.sh");
    let status = Command::new("bash")
        .arg("-c")
        .arg(format!(". '{}'; healthy", script.display()))
        .env("PATH", path)
        .env("HEALTH_URL", url)
        .env("HEALTH_PORTS", format!("127.0.0.1:{signalling} 127.0.0.1:{control}"))
        .env("PEERINGD_HEALTH_ATTEMPTS", "2")
        .status()
        .unwrap();
    let _ = std::fs::remove_dir_all(directory);
    status.success()
}

#[test]
fn a_relay_whose_listeners_and_healthz_answer_is_kept() {
    assert!(keeps_the_new_binary(Some(serve_status(200)), open_port(), open_port(), "all"));
}

#[test]
fn an_unbound_web_listener_does_not_roll_back_a_relay_whose_signalling_and_control_answer() {
    assert!(keeps_the_new_binary(None, open_port(), open_port(), "no-web"));
}

#[test]
fn a_closed_signalling_port_is_rolled_back_even_when_healthz_says_ok() {
    assert!(!keeps_the_new_binary(Some(serve_status(200)), free_port(), open_port(), "no-signalling"));
}

#[test]
fn a_closed_control_port_is_rolled_back_when_the_web_listener_is_absent() {
    assert!(!keeps_the_new_binary(None, open_port(), free_port(), "no-control"));
}

#[test]
fn a_stopped_task_reported_by_healthz_is_rolled_back() {
    assert!(!keeps_the_new_binary(Some(serve_status(503)), open_port(), open_port(), "unhealthy"));
}

#[test]
fn the_deploy_script_runs_the_decision_from_the_tested_file() {
    let script = std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("tools/deploy-relay.sh")).unwrap();
    assert!(script.contains("deploy/peeringd-deploy-health.sh"));
    assert!(script.contains("if ! healthy; then"));
}
