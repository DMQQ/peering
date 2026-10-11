//! A Google Play purchase, presented on `connectToHost`, decides the plan the connect is metered by.
//!
//! The free allowance here is zero, so a connect metered as free is refused with `quotaExceeded`
//! and a connect metered as Pro is given a session. That makes the plan visible on the wire without
//! reading the counter. Google is replaced by `FakePlayApi`, and the claim is `pro` throughout, so a
//! refusal means the claim was not believed.

use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use tokio::net::TcpListener;
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::Message;

use peeringd::config::PlanAllowances;
use peeringd::play_api::{FakePlayApi, PlayApi, PlayPurchase, PlayVerifier, PurchaseState};
use peeringd::protocol::ServerMessage;
use peeringd::quota::QuotaTracker;
use peeringd::session::Registry;
use peeringd::signalling::{self, HostRegistry, Settings};
use peeringd::storekit::StoreKitVerifier;

const PATIENCE: Duration = Duration::from_secs(5);
const PACKAGE: &str = "pl.dmq.peering";
const YEAR: &str = "pl.dmq.peering.pro.year";

type Ws = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// A relay with no free time at all, and the given Play verifier (or none).
async fn start(play: Option<Arc<PlayVerifier>>) -> u16 {
    let signal = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = signal.local_addr().unwrap().port();
    let allowances = PlanAllowances { free_seconds: Some(0), relay_seconds: Some(0) };
    let settings = Settings {
        host: Some("127.0.0.1".into()),
        public_control_port: 0,
        video_port: 0,
        session_ttl: Duration::from_secs(60),
        quota: Arc::new(QuotaTracker::new(allowances, Default::default())),
        receipts: Arc::new(StoreKitVerifier::apple(false)),
        max_sessions: usize::MAX,
        max_connections: 1 << 20,
        handshake_timeout: Duration::from_secs(10),
        idle_timeout: Duration::from_secs(90),
        apns: None,
        fcm: None,
        play,
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

fn verifier(api: impl PlayApi + 'static) -> Option<Arc<PlayVerifier>> {
    Some(Arc::new(PlayVerifier::new(PACKAGE.into(), api)))
}

fn purchase(state: PurchaseState, expiry_unix: u64) -> PlayPurchase {
    PlayPurchase {
        product_id: YEAR.into(),
        state,
        expiry_unix: Some(expiry_unix),
        obfuscated_account_id: None,
        is_lifetime: false,
    }
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

async fn send(ws: &mut Ws, message: serde_json::Value) {
    ws.send(Message::Text(message.to_string().into())).await.unwrap();
}

async fn connect(port: u16) -> Ws {
    let (ws, _) = tokio_tungstenite::connect_async(format!("ws://127.0.0.1:{port}"))
        .await
        .expect("the signalling socket should open");
    ws
}

/// A Mac that is up, so a connect has a host to be introduced to.
async fn registered_mac(port: u16) -> Ws {
    let mut mac = connect(port).await;
    send(
        &mut mac,
        json!({"type": "registerHost", "deviceId": "mac", "name": "Studio", "protocolVersion": 3}),
    )
    .await;
    assert!(matches!(next_message(&mut mac).await, ServerMessage::Registered { .. }));
    mac
}

/// Asks for a session as a client claiming Pro, optionally presenting a Play purchase, and returns
/// the relay's answer. The Mac is registered for the duration so only the plan decides the outcome.
async fn ask(port: u16, purchase: Option<(&str, &str)>) -> ServerMessage {
    let _mac = registered_mac(port).await;
    let mut phone = connect(port).await;
    let mut request = json!({
        "type": "connectToHost",
        "hostId": "mac",
        "clientId": "phone",
        "protocolVersion": 3,
        "plan": "pro",
    });
    if let Some((token, product)) = purchase {
        request["playPurchaseToken"] = json!(token);
        request["playProductId"] = json!(product);
    }
    send(&mut phone, request).await;
    loop {
        match next_message(&mut phone).await {
            ServerMessage::Pong | ServerMessage::Registered { .. } => continue,
            answer => return answer,
        }
    }
}

fn is_session(answer: &ServerMessage) -> bool {
    matches!(answer, ServerMessage::SessionReady { .. })
}

fn is_quota_refusal(answer: &ServerMessage) -> bool {
    matches!(answer, ServerMessage::Error { code, .. } if code == "quotaExceeded")
}

#[tokio::test]
async fn a_live_purchase_verified_by_google_is_pro_and_unlimited() {
    let live = purchase(PurchaseState::Active, u64::MAX / 2);
    let port = start(verifier(FakePlayApi::answering(live))).await;
    let answer = ask(port, Some(("purchase-token", YEAR))).await;
    assert!(is_session(&answer), "{answer:?}");
}

#[tokio::test]
async fn a_purchase_google_reports_expired_meters_as_free() {
    let lapsed = purchase(PurchaseState::Expired, 1);
    let port = start(verifier(FakePlayApi::answering(lapsed))).await;
    let answer = ask(port, Some(("purchase-token", YEAR))).await;
    assert!(is_quota_refusal(&answer), "{answer:?}");
}

#[tokio::test]
async fn a_purchase_that_cannot_be_checked_meters_as_free() {
    let port = start(verifier(FakePlayApi::failing("status 503"))).await;
    let answer = ask(port, Some(("purchase-token", YEAR))).await;
    assert!(is_quota_refusal(&answer), "{answer:?}");
}

#[tokio::test]
async fn with_play_not_configured_the_token_changes_nothing() {
    let port = start(None).await;
    let answer = ask(port, Some(("purchase-token", YEAR))).await;
    assert!(is_quota_refusal(&answer), "{answer:?}");
}

#[tokio::test]
async fn a_client_that_presents_no_purchase_is_metered_as_before() {
    let live = purchase(PurchaseState::Active, u64::MAX / 2);
    let port = start(verifier(FakePlayApi::answering(live))).await;
    let answer = ask(port, None).await;
    assert!(is_quota_refusal(&answer), "{answer:?}");
}
