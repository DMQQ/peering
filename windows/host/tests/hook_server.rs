
//! The hook server over a real loopback socket, with the broker behind it.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use peering_core::ports::clock::Clock;
use peering_core::terminal::hooks::broker::{Answer, HookBroker, HookPush, Phones};
use peering_host::hooks::server::{HookServer, HookServerConfig, Handler};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

const TOKEN: &str = "secret-token";
const PERMISSION: &str = r#"{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/a/app","tool_name":"Bash","tool_input":{"command":"npm test"}}"#;

struct Phone(Mutex<Vec<HookPush>>);

impl Phones for Phone {
    fn tokens(&self) -> Vec<String> {
        vec!["t".to_owned()]
    }

    fn push(&self, push: HookPush) {
        self.0.lock().expect("lock").push(push);
    }
}

struct ZeroClock;

impl Clock for ZeroClock {
    fn now_seconds(&self) -> f64 {
        0.0
    }

    fn unix_seconds(&self) -> u64 {
        0
    }
}

struct Rig {
    server: HookServer,
    broker: Arc<HookBroker>,
    phone: Arc<Phone>,
}

async fn rig(reply_deadline: Duration) -> Rig {
    let phone = Arc::new(Phone(Mutex::default()));
    let broker = Arc::new(HookBroker::new(phone.clone(), Arc::new(ZeroClock), Box::new(|| "approval-1".to_owned())));
    let handler: Handler = {
        let broker = broker.clone();
        Arc::new(move |event, reply| broker.handle(&event, reply))
    };
    let config = HookServerConfig { token: TOKEN.to_owned(), reply_deadline };
    let server = HookServer::start(0, config, handler).await.expect("binds loopback");
    Rig { server, broker, phone }
}

async fn post(port: u16, token: &str, body: &str) -> String {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).await.expect("connects");
    let request = format!(
        "POST /hook HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Peering-Token: {token}\r\nContent-Length: {}\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(request.as_bytes()).await.expect("writes");
    let mut response = String::new();
    stream.read_to_string(&mut response).await.expect("reads");
    response
}

#[tokio::test]
async fn an_allow_from_the_phone_reaches_the_waiting_hook() {
    let rig = rig(Duration::from_secs(30)).await;
    let waiting = tokio::spawn(post(rig.server.port(), TOKEN, PERMISSION));
    while rig.phone.0.lock().expect("lock").is_empty() {
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    assert!(rig.broker.resolve("approval-1", Answer::Allow));
    let response = waiting.await.expect("task");
    assert!(response.starts_with("HTTP/1.1 200 OK"), "{response}");
    assert!(response.contains(r#""behavior":"allow""#), "{response}");
}

#[tokio::test]
async fn a_wrong_token_is_forbidden_and_reaches_nobody() {
    let rig = rig(Duration::from_secs(30)).await;
    let response = post(rig.server.port(), "guess", PERMISSION).await;
    assert!(response.starts_with("HTTP/1.1 403"), "{response}");
    assert!(rig.phone.0.lock().expect("lock").is_empty());
}

#[tokio::test]
async fn a_body_over_the_bound_is_refused() {
    let rig = rig(Duration::from_secs(30)).await;
    let response = post(rig.server.port(), TOKEN, &"x".repeat(600 * 1024)).await;
    assert!(response.starts_with("HTTP/1.1 413"), "{response}");
}

#[tokio::test]
async fn text_that_is_not_a_hook_line_is_a_bad_request() {
    let rig = rig(Duration::from_secs(30)).await;
    let response = post(rig.server.port(), TOKEN, "not json").await;
    assert!(response.starts_with("HTTP/1.1 400"), "{response}");
}

#[tokio::test]
async fn a_hook_nobody_answers_is_released_with_no_content() {
    let rig = rig(Duration::from_millis(50)).await;
    let response = post(rig.server.port(), TOKEN, PERMISSION).await;
    assert!(response.starts_with("HTTP/1.1 204"), "{response}");
}

#[tokio::test]
async fn an_event_that_needs_no_answer_is_released_at_once() {
    let rig = rig(Duration::from_secs(30)).await;
    let response = post(rig.server.port(), TOKEN, r#"{"hook_event_name":"Stop","session_id":"s1"}"#).await;
    assert!(response.starts_with("HTTP/1.1 204"), "{response}");
}
