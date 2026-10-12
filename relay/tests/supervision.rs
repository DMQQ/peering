//! The process as systemd sees it: stopped by SIGTERM, reporting health, and checked by the
//! health script.

#![cfg(unix)]

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

fn http_status(port: u16) -> String {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
    stream.write_all(b"GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").unwrap();
    let mut reply = String::new();
    let _ = stream.read_to_string(&mut reply);
    reply.lines().next().unwrap_or_default().to_string()
}

#[test]
fn sigterm_stops_the_relay_cleanly_and_healthz_answers_while_it_runs() {
    let web_port = free_port();
    let mut child = Command::new(env!("CARGO_BIN_EXE_peeringd"))
        .env_clear()
        .env("PEERINGD_SIGNAL_ADDR", "127.0.0.1:0")
        .env("PEERINGD_CONTROL_ADDR", "127.0.0.1:0")
        .env("PEERINGD_VIDEO_BIND", "127.0.0.1:0")
        .env("PEERINGD_WEB_ADDR", format!("127.0.0.1:{web_port}"))
        .env("PEERINGD_WEB_ROOT", Path::new(env!("CARGO_MANIFEST_DIR")).join("no-such-site"))
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("the relay binary should start");

    let (lines_tx, lines) = mpsc::channel();
    let stdout = child.stdout.take().unwrap();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if lines_tx.send(line).is_err() {
                break;
            }
        }
    });

    let mut log = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    while !log.iter().any(|line: &String| line.contains("peeringd ready")) {
        let wait = deadline.saturating_duration_since(Instant::now());
        log.push(lines.recv_timeout(wait).expect("the relay should report ready"));
    }
    // The site is deliberately missing: the health listener must bind without it.
    let deadline = Instant::now() + Duration::from_secs(5);
    while TcpStream::connect(("127.0.0.1", web_port)).is_err() {
        assert!(Instant::now() < deadline, "the health listener should bind without a site");
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(http_status(web_port).contains("200"), "healthz answers while every task runs");

    let signalled = Command::new("kill").args(["-TERM", &child.id().to_string()]).status().unwrap();
    assert!(signalled.success());

    let deadline = Instant::now() + Duration::from_secs(5);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        assert!(Instant::now() < deadline, "SIGTERM should stop the relay");
        std::thread::sleep(Duration::from_millis(50));
    };
    assert!(status.success(), "a requested stop is a clean exit, got {status}");

    log.extend(lines.try_iter());
    assert!(log.iter().any(|line| line.contains("stopping")), "the shutdown path ran: {log:?}");
}

fn serve_status(status: u16) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for stream in listener.incoming().map_while(Result::ok) {
            let mut stream = stream;
            let mut buffer = [0u8; 1024];
            let _ = stream.read(&mut buffer);
            let _ = write!(stream, "HTTP/1.1 {status} X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        }
    });
    port
}

/// A directory of stand-ins for the commands the script calls, so that "restart" is a file that
/// appears and nothing sleeps.
fn stubs(name: &str) -> PathBuf {
    let directory = std::env::temp_dir().join(format!("peeringd-health-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    std::fs::create_dir_all(&directory).unwrap();
    let write = |file: &str, body: &str| {
        let path = directory.join(file);
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    };
    write("systemctl", &format!("[ \"$1\" = restart ] && touch {}/restarted; exit 0", directory.display()));
    write("logger", "exit 0");
    write("sleep", "exit 0");
    write("timeout", "shift; exec \"$@\"");
    directory
}

fn restarted(web: Option<u16>, ports: &[u16], name: &str) -> bool {
    let directory = stubs(name);
    let path = format!("{}:{}", directory.display(), std::env::var("PATH").unwrap());
    let url = match web {
        Some(port) => format!("http://127.0.0.1:{port}/healthz"),
        None => format!("http://127.0.0.1:{}/healthz", free_port()),
    };
    let endpoints: Vec<String> = ports.iter().map(|port| format!("127.0.0.1:{port}")).collect();
    let status = Command::new("bash")
        .arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("deploy/peeringd-healthcheck.sh"))
        .env("PATH", path)
        .env("PEERINGD_HEALTHCHECK_URL", url)
        .env("PEERINGD_HEALTHCHECK_PORTS", endpoints.join(" "))
        .status()
        .unwrap();
    assert!(status.success());
    let restarted = directory.join("restarted").exists();
    let _ = std::fs::remove_dir_all(directory);
    restarted
}

fn open_port() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || for _ in listener.incoming() {});
    port
}

#[test]
fn the_health_script_leaves_a_relay_alone_when_healthz_says_ok() {
    assert!(!restarted(Some(serve_status(200)), &[], "ok"));
}

#[test]
fn the_health_script_restarts_a_relay_that_reports_a_stopped_task() {
    assert!(restarted(Some(serve_status(503)), &[open_port()], "unhealthy"));
}

#[test]
fn a_missing_web_listener_is_not_a_reason_to_restart_while_the_real_listeners_answer() {
    assert!(!restarted(None, &[open_port(), open_port()], "no-web"));
}

#[test]
fn the_health_script_restarts_when_the_web_listener_is_absent_and_a_real_listener_is_not() {
    assert!(restarted(None, &[open_port(), free_port()], "no-signalling"));
}
