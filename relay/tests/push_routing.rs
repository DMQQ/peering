//! Which service carries a `notifyDevice`, decided by the token it names.
//!
//! The APNs sender is a concrete client that needs Apple's key to exist, so these tests prove the
//! routing from the FCM side: an Android token must reach the FCM sender, and an iOS token must not
//! reach it. The APNs path itself is unchanged and is covered by `apns`' own tests.

use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use tokio::net::TcpListener;
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::Message;

use peeringd::config::PlanAllowances;
use peeringd::fcm::{FakeAccessTokens, FakeFcmTransport, FcmClient, SentPost, SentPosts};
use peeringd::protocol::ServerMessage;
use peeringd::quota::QuotaTracker;
use peeringd::session::Registry;
use peeringd::signalling::{HostRegistry, Settings};
use peeringd::storekit::StoreKitVerifier;
use peeringd::signalling;

const PATIENCE: Duration = Duration::from_secs(5);

type Ws = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn start(fcm: Option<Arc<FcmClient>>) -> u16 {
    let signal = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = signal.local_addr().unwrap().port();
    let settings = Settings {
        host: Some("127.0.0.1".into()),
        public_control_port: 0,
        video_port: 0,
        session_ttl: Duration::from_secs(60),
        quota: Arc::new(QuotaTracker::new(PlanAllowances::default(), Default::default())),
        receipts: Arc::new(StoreKitVerifier::apple(false)),
        max_sessions: usize::MAX,
        max_connections: 1 << 20,
        handshake_timeout: Duration::from_secs(10),
        idle_timeout: Duration::from_secs(90),
        apns: None,
        fcm,
        play: None,
    };
    tokio::spawn(signalling::serve(
        signal,
        Arc::new(Registry::new(usize::MAX)),
        HostRegistry::new(),
        settings,
        None,
    ));
    port
}

fn fcm_with(transport: FakeFcmTransport) -> Arc<FcmClient> {
    Arc::new(FcmClient::new(
        "peering-test".to_owned(),
        FakeAccessTokens::giving("ya29.test"),
        transport,
    ))
}

async fn send(ws: &mut Ws, message: serde_json::Value) {
    ws.send(Message::Text(message.to_string().into())).await.unwrap();
}

async fn next_message(ws: &mut Ws) -> ServerMessage {
    loop {
        let message = timeout(PATIENCE, ws.next())
            .await
            .expect("timed out waiting for a message")
            .expect("the stream ended early")
            .expect("the websocket errored");
        if let Message::Text(text) = message {
            return serde_json::from_str(&text).expect("a ServerMessage");
        }
    }
}

/// Connects and registers a Mac, so that its `notifyDevice` messages are honoured.
async fn registered_mac(port: u16) -> Ws {
    let (mut ws, _) = tokio_tungstenite::connect_async(format!("ws://127.0.0.1:{port}"))
        .await
        .expect("the signalling socket should open");
    send(
        &mut ws,
        json!({"type": "registerHost", "deviceId": "studio", "name": "Studio", "protocolVersion": 3}),
    )
    .await;
    assert!(matches!(next_message(&mut ws).await, ServerMessage::Registered { .. }));
    ws
}

/// The token as a Mac sends it: the bytes a phone registered, hex encoded.
fn hex_of(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn notify(device_token: &str) -> serde_json::Value {
    json!({"type": "notifyDevice", "deviceToken": device_token, "title": "Done", "body": "Build finished"})
}

/// Waits for the spawned push to reach the transport, which is the only way to know it ran.
async fn first_post(sent: &SentPosts) -> SentPost {
    timeout(PATIENCE, async {
        loop {
            if let Some(post) = sent.lock().unwrap().first().cloned() {
                return post;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("the FCM sender should have been asked to push")
}

/// A ping is answered after the notify before it has been dispatched, so once the pong is back the
/// notify has either spawned a send or dropped the push.
async fn settle(ws: &mut Ws) {
    send(ws, json!({"type": "ping"})).await;
    assert!(matches!(next_message(ws).await, ServerMessage::Pong));
}

#[tokio::test]
async fn an_android_token_reaches_the_fcm_sender() {
    let (transport, sent) = FakeFcmTransport::answering(200, "{}");
    let port = start(Some(fcm_with(transport))).await;
    let mut mac = registered_mac(port).await;

    let token = hex_of(b"fcm:abc123:APA91b-_x");
    send(&mut mac, notify(&token)).await;

    let post = first_post(&sent).await;
    assert_eq!(post.url, "https://fcm.googleapis.com/v1/projects/peering-test/messages:send");
    assert_eq!(post.bearer, "ya29.test");
    let body: serde_json::Value = serde_json::from_str(&post.body).unwrap();
    assert_eq!(body["message"]["token"], "abc123:APA91b-_x");
    assert_eq!(body["message"]["data"]["hostId"], "studio");
}

#[tokio::test]
async fn an_ios_token_never_reaches_the_fcm_sender() {
    let (transport, sent) = FakeFcmTransport::answering(200, "{}");
    let port = start(Some(fcm_with(transport))).await;
    let mut mac = registered_mac(port).await;

    send(&mut mac, notify(&"ab".repeat(32))).await;
    settle(&mut mac).await;
    assert!(sent.lock().unwrap().is_empty());
}

#[tokio::test]
async fn without_fcm_configured_an_android_push_is_dropped_and_the_socket_carries_on() {
    let port = start(None).await;
    let mut mac = registered_mac(port).await;

    let token = hex_of(b"fcm:abc123");
    send(&mut mac, notify(&token)).await;
    settle(&mut mac).await;
}
