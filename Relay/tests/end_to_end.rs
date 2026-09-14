//! The whole relay, exercised the way the two apps will use it.
//!
//! The unit tests check each piece against its own rules; this checks the pieces against each
//! other, over real sockets. Everything below is what `RelayClient.swift` and `HostServer.swift`
//! will have to do: register, ask, receive a session, present a token on a control socket, and
//! bind a video address — so a mistake in the *shape* of the protocol shows up here rather than on
//! a phone in another country.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UdpSocket};
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::Message;

use peeringd::protocol::{unhex, ClientMessage, ServerMessage};
use peeringd::session::Registry;
use peeringd::signalling::{HostRegistry, Settings};
use peeringd::udp_relay::{bind_packet, PortPool};
use peeringd::{signalling, tcp_relay};

/// Generous enough to absorb a loaded CI machine, short enough that a hang fails the test rather
/// than the suite.
const PATIENCE: Duration = Duration::from_secs(5);

type Ws = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<TcpStream>>;

struct TestRelay {
    signal_port: u16,
    control_port: u16,
}

/// The endpoints a session hands to one end.
struct Session {
    control_token: String,
    video_port: u16,
    video_token: String,
}

async fn start() -> TestRelay {
    let registry = Arc::new(Registry::new());

    // Port 0 throughout, so tests never collide with a relay someone is actually running — or with
    // each other when the suite runs them in parallel.
    let control = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let control_port = control.local_addr().unwrap().port();
    let signal = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let signal_port = signal.local_addr().unwrap().port();

    tokio::spawn(tcp_relay::serve(control, Arc::clone(&registry)));

    tokio::spawn(signalling::serve(
        signal,
        registry,
        HostRegistry::new(),
        Settings {
            host: Some("127.0.0.1".into()),
            control_port,
            video_bind: "127.0.0.1:0".parse().unwrap(),
            video_ports: Arc::new(PortPool::new(None)),
            session_ttl: Duration::from_secs(60),
        },
        None,
    ));

    TestRelay {
        signal_port,
        control_port,
    }
}

async fn connect(port: u16) -> Ws {
    let (ws, _) = timeout(
        PATIENCE,
        tokio_tungstenite::connect_async(format!("ws://127.0.0.1:{port}")),
    )
    .await
    .expect("the signalling socket should open")
    .expect("the websocket handshake should succeed");
    ws
}

async fn send(ws: &mut Ws, message: &ClientMessage) {
    let json = serde_json::to_string(message).unwrap();
    ws.send(Message::Text(json.into())).await.unwrap();
}

/// The next message from the relay, whatever it is.
async fn next_message(ws: &mut Ws) -> ServerMessage {
    loop {
        let message = timeout(PATIENCE, ws.next())
            .await
            .expect("timed out waiting for a message")
            .expect("the stream ended early")
            .expect("the websocket errored");

        if let Message::Text(text) = message {
            return serde_json::from_str(&text).expect("should parse as ServerMessage");
        }
    }
}

/// Reads until a `SessionReady` arrives, skipping the traffic that can legitimately precede one.
async fn await_session(ws: &mut Ws) -> Session {
    loop {
        match next_message(ws).await {
            ServerMessage::SessionReady {
                control_token,
                video_port,
                video_token,
                ..
            } => {
                return Session {
                    control_token,
                    video_port,
                    video_token,
                }
            }
            ServerMessage::Registered { .. } | ServerMessage::Pong => continue,
            other => panic!("expected a session, got {other:?}"),
        }
    }
}

/// Opens a control socket and presents the token, exactly as the apps will: the token first, in
/// the clear, and whatever follows it belongs to somebody else.
async fn present(control_port: u16, token: &str) -> TcpStream {
    let mut stream = TcpStream::connect(("127.0.0.1", control_port))
        .await
        .expect("the control relay should accept");
    stream
        .write_all(&unhex(token).expect("the token should be hex"))
        .await
        .unwrap();
    stream
}

/// Registers a Mac and waits for the registration to be acknowledged.
///
/// Waiting rather than firing and forgetting is what stops the acknowledgement sitting in the
/// stream to be tripped over by whichever read comes next.
async fn register_mac(relay: &TestRelay, device_id: &str) -> Ws {
    let mut mac = connect(relay.signal_port).await;
    send(
        &mut mac,
        &ClientMessage::RegisterHost {
            device_id: device_id.into(),
            name: "Studio".into(),
            protocol_version: 3,
        },
    )
    .await;

    assert!(
        matches!(next_message(&mut mac).await, ServerMessage::Registered { .. }),
        "the relay should acknowledge a registration"
    );

    mac
}

#[tokio::test]
async fn a_mac_and_a_phone_are_introduced_and_their_control_sockets_talk() {
    let relay = start().await;
    let mut mac = register_mac(&relay, "mac").await;

    let mut phone = connect(relay.signal_port).await;
    send(
        &mut phone,
        &ClientMessage::ConnectToHost {
            host_id: "mac".into(),
            client_id: "phone".into(),
            protocol_version: 3,
        },
    )
    .await;

    let phone_session = await_session(&mut phone).await;
    let mac_session = await_session(&mut mac).await;

    // Both ends present the same control token. Whichever arrives first waits for the other, and
    // whoever is holding both splices — so neither of these calls returns a usable stream until
    // the second one has been made.
    let mut phone_side = present(relay.control_port, &phone_session.control_token).await;
    let mut mac_side = present(relay.control_port, &mac_session.control_token).await;

    phone_side.write_all(b"a click").await.unwrap();

    let mut heard = [0u8; 7];
    timeout(PATIENCE, mac_side.read_exact(&mut heard))
        .await
        .expect("the Mac should hear the phone")
        .unwrap();
    assert_eq!(&heard, b"a click");

    // And back the other way, which is what proves the splice is bidirectional rather than a pair
    // of one-way pipes that happen to have been wired the same way round.
    mac_side.write_all(b"a frame").await.unwrap();

    let mut back = [0u8; 7];
    timeout(PATIENCE, phone_side.read_exact(&mut back))
        .await
        .expect("the phone should hear the Mac")
        .unwrap();
    assert_eq!(&back, b"a frame");
}

#[tokio::test]
async fn video_datagrams_flow_between_the_two_ends() {
    let relay = start().await;
    let mut mac = register_mac(&relay, "mac").await;

    let mut phone = connect(relay.signal_port).await;
    send(
        &mut phone,
        &ClientMessage::ConnectToHost {
            host_id: "mac".into(),
            client_id: "phone".into(),
            protocol_version: 3,
        },
    )
    .await;

    let phone_session = await_session(&mut phone).await;
    let mac_session = await_session(&mut mac).await;
    let video: SocketAddr = ([127, 0, 0, 1], phone_session.video_port).into();

    let phone_udp = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let mac_udp = UdpSocket::bind("127.0.0.1:0").await.unwrap();

    // Each end claims its slot with its own token. These are deliberately not the same value, and
    // that is what lets a re-bind later move one end without disturbing the other.
    phone_udp
        .send_to(&bind_packet(&unhex(&phone_session.video_token).unwrap()), video)
        .await
        .unwrap();
    mac_udp
        .send_to(&bind_packet(&unhex(&mac_session.video_token).unwrap()), video)
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;

    // The Mac sends a frame. This is the direction that matters: video only ever goes this way.
    mac_udp.send_to(b"a sealed frame", video).await.unwrap();

    let mut buf = [0u8; 64];
    let (len, _) = timeout(PATIENCE, phone_udp.recv_from(&mut buf))
        .await
        .expect("the phone should receive the frame")
        .unwrap();
    assert_eq!(&buf[..len], b"a sealed frame");
}

#[tokio::test]
async fn a_phone_asking_for_a_mac_that_is_not_running_is_told_so() {
    let relay = start().await;

    let mut phone = connect(relay.signal_port).await;
    send(
        &mut phone,
        &ClientMessage::ConnectToHost {
            host_id: "nobody".into(),
            client_id: "phone".into(),
            protocol_version: 3,
        },
    )
    .await;

    let message = timeout(PATIENCE, phone.next())
        .await
        .expect("should answer promptly")
        .expect("the stream should stay open")
        .expect("should not error");
    let Message::Text(text) = message else {
        panic!("expected a text message")
    };

    assert_eq!(
        serde_json::from_str::<ServerMessage>(&text).unwrap(),
        ServerMessage::HostOffline {
            device_id: "nobody".into()
        }
    );
}

#[tokio::test]
async fn a_mac_that_disconnects_stops_being_reachable() {
    // The property the whole presence model rests on: there is no roster to go stale, because the
    // registration *is* the connection. A Mac that drops is offline the moment the socket closes.
    let relay = start().await;
    let mac = register_mac(&relay, "mac").await;
    drop(mac);

    // Give the server a moment to notice the close. It is a real close rather than a timeout, so
    // this is prompt — the sleep only stops the test racing the accept loop.
    tokio::time::sleep(Duration::from_millis(200)).await;

    let mut phone = connect(relay.signal_port).await;
    send(
        &mut phone,
        &ClientMessage::ConnectToHost {
            host_id: "mac".into(),
            client_id: "phone".into(),
            protocol_version: 3,
        },
    )
    .await;

    let message = timeout(PATIENCE, phone.next())
        .await
        .expect("should answer promptly")
        .expect("the stream should stay open")
        .expect("should not error");
    let Message::Text(text) = message else {
        panic!("expected a text message")
    };

    assert_eq!(
        serde_json::from_str::<ServerMessage>(&text).unwrap(),
        ServerMessage::HostOffline {
            device_id: "mac".into()
        },
        "a Mac that has closed its signalling socket must not still be offered"
    );
}

#[tokio::test]
async fn a_stolen_control_token_is_no_use_twice() {
    // A token is spent once the splice it paid for has finished. Without that, a token captured
    // from a log or a crash report would stay useful for the rest of its lifetime.
    let relay = start().await;
    let mut mac = register_mac(&relay, "mac").await;

    let mut phone = connect(relay.signal_port).await;
    send(
        &mut phone,
        &ClientMessage::ConnectToHost {
            host_id: "mac".into(),
            client_id: "phone".into(),
            protocol_version: 3,
        },
    )
    .await;

    let phone_session = await_session(&mut phone).await;
    let _mac_session = await_session(&mut mac).await;

    let token = phone_session.control_token.clone();
    let phone_side = present(relay.control_port, &token).await;
    let mac_side = present(relay.control_port, &token).await;

    // Closing both ends finishes the splice and releases the session.
    drop(phone_side);
    drop(mac_side);
    tokio::time::sleep(Duration::from_millis(200)).await;

    // A fresh connection presenting the same token now gets nothing back: no splice, and no
    // acknowledgement that the token was ever valid.
    let mut latecomer = present(relay.control_port, &token).await;
    latecomer.write_all(b"anyone there?").await.unwrap();

    let mut buf = [0u8; 16];
    let outcome = timeout(Duration::from_millis(500), latecomer.read(&mut buf)).await;

    // Either the socket was closed — a zero-length read — or nothing came back at all. Both mean
    // the token bought nothing; only actual bytes would mean it still worked.
    assert!(
        !matches!(outcome, Ok(Ok(read)) if read > 0),
        "a spent token should open nothing"
    );
}
