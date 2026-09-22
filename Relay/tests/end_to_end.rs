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

use peeringd::config::PlanAllowances;
use peeringd::protocol::{unhex, ClientMessage, ServerMessage};
use peeringd::quota::{Plan, QuotaTracker};
use peeringd::session::Registry;
use peeringd::signalling::{HostRegistry, Settings};
use peeringd::storekit::StoreKitVerifier;
use peeringd::{signalling, tcp_relay, udp_relay};

/// Generous enough to absorb a loaded CI machine, short enough that a hang fails the test rather
/// than the suite.
const PATIENCE: Duration = Duration::from_secs(5);

type Ws = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<TcpStream>>;

struct TestRelay {
    signal_port: u16,
    control_port: u16,
    /// The one port every session is told to send video to, whoever it belongs to.
    video_port: u16,
}

/// The endpoints a session hands to one end.
struct Session {
    control_token: String,
    video_port: u16,
    video_token: String,
}

/// Every test's relay, metered by the defaults: one hour free, paid plans unlimited, and a splice
/// charged every `CHARGE_PERIOD`.
async fn start() -> TestRelay {
    start_with(Arc::new(QuotaTracker::new(
        PlanAllowances::default(),
        Default::default(),
    )))
    .await
}

/// The same relay with a counter the caller built, which is what the metering tests need: they set
/// an allowance small enough to spend inside a test and a charge period short enough to watch, and
/// they read the counter back afterwards.
async fn start_with(quota: Arc<QuotaTracker>) -> TestRelay {
    start_with_timeouts(quota, Duration::from_secs(10), Duration::from_secs(90)).await
}

/// The same relay with the two signalling deadlines the caller chooses.
///
/// Only the two tests about *refusing* a connection want short ones; everything else wants
/// deadlines long enough that they cannot be what a failure is about.
async fn start_with_timeouts(
    quota: Arc<QuotaTracker>,
    handshake_timeout: Duration,
    idle_timeout: Duration,
) -> TestRelay {
    let registry = Arc::new(Registry::new(usize::MAX));

    // Port 0 throughout, so tests never collide with a relay someone is actually running — or with
    // each other when the suite runs them in parallel.
    let control = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let control_port = control.local_addr().unwrap().port();
    let signal = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let signal_port = signal.local_addr().unwrap().port();

    tokio::spawn(tcp_relay::serve(control, Arc::clone(&registry)));

    // The relay's one video socket, bound exactly as `main` binds it and before signalling starts,
    // so that the port every session is told is the port that exists.
    let video = udp_relay::serve(
        "127.0.0.1:0".parse().unwrap(),
        registry.routes(),
        Duration::from_secs(60),
    )
    .await
    .expect("the video socket should bind");

    tokio::spawn(signalling::serve(
        signal,
        registry,
        HostRegistry::new(),
        Settings {
            host: Some("127.0.0.1".into()),
            public_control_port: control_port,
            video_port: video.port(),
            session_ttl: Duration::from_secs(60),
            quota,
            // Pinned to Apple's real root, so nothing this test sends can be mistaken for a
            // receipt. The verified path has its own tests, with a chain they can sign.
            //
            // Claims are trusted, which is **not** the shipped default: `PEERINGD_TRUST_CLAIMED_PLANS`
            // is closed out of the box and this stands in for an operator who has opened it. The
            // metering tests below are about what the relay does with a plan once it has one, and
            // the switch is the cheapest way to give it one; a *verified* Pro receipt would need a
            // chain the test can sign, which `tests/storekit.rs` builds and this file does not.
            receipts: Arc::new(StoreKitVerifier::apple(true)),
            // No ceiling in these tests, and no timeouts short enough to interfere with them: they
            // are about what the relay does with a session, not about what it refuses. Both have
            // their own tests.
            max_sessions: usize::MAX,
            max_connections: 1 << 20,
            handshake_timeout,
            idle_timeout,
            apns: None,
        },
        None,
    ));

    TestRelay {
        signal_port,
        control_port,
        video_port: video.port(),
    }
}

/// One video datagram as an end produces it: its own token, a counter, the sealed bytes and the
/// tag. Everything past the first sixteen bytes is the two ends' business and the relay reads none
/// of it — this shape is only here so the test can check what comes out the other side.
fn video_datagram(token: &str, counter: u64, sealed: &[u8]) -> Vec<u8> {
    let mut packet = unhex(token).expect("the token should be hex").to_vec();
    packet.extend_from_slice(&counter.to_be_bytes());
    packet.extend_from_slice(sealed);
    packet.extend_from_slice(&[0u8; 16]); // The AEAD tag. The relay never looks at it.
    packet
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
        // Unproved, which is what a Mac in the field sends today and what these tests are about.
        // The proving path has its own tests in `device_proof` and `device_bindings`; what matters
        // here is that the older shape still registers, because on the day this ships every Mac in
        // the field is sending exactly this.
        &ClientMessage::RegisterHost {
            device_id: device_id.into(),
            name: "Studio".into(),
            protocol_version: 3,
            public_key: None,
            proof: None,
            proof_time: None,
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
            api_key: None,
            // What the app sends for a user who has bought nothing. The relay reads the field
            // leniently — see `Plan::from_wire` — and this is the spelling that must never be
            // mistaken for a paid one.
            plan: Some("free".into()),
            // No receipt: what the app sends until `Transaction.currentEntitlements` has answered,
            // and what every client that has bought nothing sends for its whole life.
            jws_representation: None,
            public_key: None,
            proof: None,
            proof_time: None,
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
            api_key: None,
            plan: Some("free".into()),
            jws_representation: None,
            public_key: None,
            proof: None,
            proof_time: None,
        },
    )
    .await;

    let phone_session = await_session(&mut phone).await;
    let mac_session = await_session(&mut mac).await;

    // Both ends are told the same port, because there is only one: the relay's, not the session's.
    assert_eq!(phone_session.video_port, relay.video_port);
    assert_eq!(mac_session.video_port, relay.video_port);
    let video: SocketAddr = ([127, 0, 0, 1], relay.video_port).into();

    let phone_udp = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let mac_udp = UdpSocket::bind("127.0.0.1:0").await.unwrap();

    // Each end claims its slot by sending its own token and nothing else. That bare token is the
    // bind: it registers the address the datagram came from, and there is nothing in it to forward.
    phone_udp
        .send_to(&unhex(&phone_session.video_token).unwrap(), video)
        .await
        .unwrap();
    mac_udp
        .send_to(&unhex(&mac_session.video_token).unwrap(), video)
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;

    // The Mac sends a frame. This is the direction that matters: video only ever goes this way.
    let frame = video_datagram(&mac_session.video_token, 7, b"a sealed frame");
    mac_udp.send_to(&frame, video).await.unwrap();

    let mut buf = [0u8; 64];
    let (len, _) = timeout(PATIENCE, phone_udp.recv_from(&mut buf))
        .await
        .expect("the phone should receive the frame")
        .unwrap();

    // Everything but the prefix, byte for byte: the counter and the sealed frame, with no sixteen
    // bytes of the Mac's token left in front of them for the phone to choke on.
    assert_eq!(&buf[..len], &frame[16..]);
}

/// The introduction: an end can ask where the other one is, and is told the address the relay saw.
///
/// This is the message that makes the relay a rendezvous rather than a conduit, so what it has to
/// get right is narrow and worth pinning exactly: that the answer is the *peer's* address rather
/// than the asker's own, that asking early is an answerable state rather than a failure, and that
/// asking is never a way to put anything into the routing table.
#[tokio::test]
async fn an_end_can_learn_where_its_peer_is() {
    let relay = start().await;
    let mut mac = register_mac(&relay, "mac").await;

    let mut phone = connect(relay.signal_port).await;
    send(
        &mut phone,
        &ClientMessage::ConnectToHost {
            host_id: "mac".into(),
            client_id: "phone".into(),
            protocol_version: 3,
            api_key: None,
            plan: Some("free".into()),
            jws_representation: None,
            public_key: None,
            proof: None,
            proof_time: None,
        },
    )
    .await;

    let phone_session = await_session(&mut phone).await;
    let mac_session = await_session(&mut mac).await;

    // The ordinary first answer. A client asks as soon as it has a session and before it has sent
    // anything, so this state is the one that will actually be hit in the field — and it has to be
    // a reply rather than a closed connection, because the caller's next move is to ask again.
    send(
        &mut phone,
        &ClientMessage::RequestPeerAddress {
            video_token: phone_session.video_token.clone(),
        },
    )
    .await;
    match next_message(&mut phone).await {
        ServerMessage::Error { code, .. } => assert_eq!(code, "peerAddressUnknown"),
        other => panic!("expected an unknown-peer error, got {other:?}"),
    }

    let video: SocketAddr = ([127, 0, 0, 1], relay.video_port).into();
    let phone_udp = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let mac_udp = UdpSocket::bind("127.0.0.1:0").await.unwrap();

    // Each end binds its slot with a bare token, which is all the relay needs to have seen one of
    // them. Nothing is forwarded and nothing is answered; this is the address being learned.
    phone_udp
        .send_to(&unhex(&phone_session.video_token).unwrap(), video)
        .await
        .unwrap();
    mac_udp
        .send_to(&unhex(&mac_session.video_token).unwrap(), video)
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;

    send(
        &mut phone,
        &ClientMessage::RequestPeerAddress {
            video_token: phone_session.video_token.clone(),
        },
    )
    .await;

    match next_message(&mut phone).await {
        ServerMessage::PeerAddress { host, port } => {
            assert_eq!(host, "127.0.0.1");
            assert_eq!(
                port,
                mac_udp.local_addr().unwrap().port(),
                "the Mac's own address, not the relay's and not the phone's"
            );
        }
        other => panic!("expected the peer's address, got {other:?}"),
    }

    // And the same question asked by the Mac answers with the phone, which is what makes the pair
    // symmetric: both ends can start a direct path, so neither has to be the one that dials.
    send(
        &mut mac,
        &ClientMessage::RequestPeerAddress {
            video_token: mac_session.video_token.clone(),
        },
    )
    .await;

    match next_message(&mut mac).await {
        ServerMessage::PeerAddress { port, .. } => {
            assert_eq!(port, phone_udp.local_addr().unwrap().port())
        }
        other => panic!("expected the phone's address, got {other:?}"),
    }
}

#[tokio::test]
async fn two_sessions_share_the_one_video_port_without_crossing() {
    // What the shared socket is for, end to end. On the old design this test is impossible on the
    // deployment that has one forwarded port: the second session is refused a video socket, because
    // the only port in the range is held by the first. Here both sessions are handed the same port
    // and the token in front of each datagram is what keeps them apart.
    let relay = start().await;
    let mut first_mac = register_mac(&relay, "mac-one").await;
    let mut second_mac = register_mac(&relay, "mac-two").await;

    let mut first_phone = connect(relay.signal_port).await;
    send(
        &mut first_phone,
        &ClientMessage::ConnectToHost {
            host_id: "mac-one".into(),
            client_id: "phone-one".into(),
            protocol_version: 3,
            api_key: None,
            plan: Some("free".into()),
            jws_representation: None,
            public_key: None,
            proof: None,
            proof_time: None,
        },
    )
    .await;
    let mut second_phone = connect(relay.signal_port).await;
    send(
        &mut second_phone,
        &ClientMessage::ConnectToHost {
            host_id: "mac-two".into(),
            client_id: "phone-two".into(),
            protocol_version: 3,
            api_key: None,
            plan: Some("free".into()),
            jws_representation: None,
            public_key: None,
            proof: None,
            proof_time: None,
        },
    )
    .await;

    let first_phone_session = await_session(&mut first_phone).await;
    let first_mac_session = await_session(&mut first_mac).await;
    let second_phone_session = await_session(&mut second_phone).await;
    let second_mac_session = await_session(&mut second_mac).await;

    assert_eq!(
        first_phone_session.video_port, second_phone_session.video_port,
        "two sessions, one port"
    );
    let video: SocketAddr = ([127, 0, 0, 1], relay.video_port).into();

    let first_phone_udp = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let first_mac_udp = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let second_phone_udp = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let second_mac_udp = UdpSocket::bind("127.0.0.1:0").await.unwrap();

    for (socket, session) in [
        (&first_phone_udp, &first_phone_session),
        (&first_mac_udp, &first_mac_session),
        (&second_phone_udp, &second_phone_session),
        (&second_mac_udp, &second_mac_session),
    ] {
        socket
            .send_to(&unhex(&session.video_token).unwrap(), video)
            .await
            .unwrap();
    }
    tokio::time::sleep(Duration::from_millis(50)).await;

    let first_frame = video_datagram(&first_mac_session.video_token, 1, b"first Mac's frame");
    let second_frame = video_datagram(&second_mac_session.video_token, 1, b"second Mac's frame");
    first_mac_udp.send_to(&first_frame, video).await.unwrap();
    second_mac_udp.send_to(&second_frame, video).await.unwrap();

    let mut buf = [0u8; 128];
    let (len, _) = timeout(PATIENCE, first_phone_udp.recv_from(&mut buf))
        .await
        .expect("the first phone should receive its Mac's frame")
        .unwrap();
    assert_eq!(&buf[..len], &first_frame[16..]);

    let (len, _) = timeout(PATIENCE, second_phone_udp.recv_from(&mut buf))
        .await
        .expect("the second phone should receive its Mac's frame")
        .unwrap();
    assert_eq!(&buf[..len], &second_frame[16..]);
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
            api_key: None,
            plan: Some("free".into()),
            jws_representation: None,
            public_key: None,
            proof: None,
            proof_time: None,
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
            api_key: None,
            plan: Some("free".into()),
            jws_representation: None,
            public_key: None,
            proof: None,
            proof_time: None,
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
            api_key: None,
            plan: Some("free".into()),
            jws_representation: None,
            public_key: None,
            proof: None,
            proof_time: None,
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

// MARK: - What a running session is charged

/// The connect request the metering tests below make, so that what they vary is visibly the plan
/// and nothing else.
fn connect_request(plan: Option<&str>) -> ClientMessage {
    ClientMessage::ConnectToHost {
        host_id: "mac".into(),
        client_id: "phone".into(),
        protocol_version: 3,
        api_key: None,
        plan: plan.map(str::to_string),
        jws_representation: None,
        public_key: None,
        proof: None,
        proof_time: None,
    }
}

/// A session with its control splice running: a phone and a Mac introduced by the relay, both
/// having presented the same control token, and one byte already carried from one end to the other.
struct Splice {
    phone: TcpStream,
    mac: TcpStream,
    /// Kept open because the tests below ask the relay questions over it once the splice is over: a
    /// client whose session was ended for money is a client that comes back and asks for another.
    phone_ws: Ws,
    /// And the Mac's, held for the same reason and read by nobody: a registration that dropped
    /// mid-session would leave the relay with a session whose host is offline, and a test that
    /// expects a refusal for money wants the money to be the only reason it could have been.
    _mac_ws: Ws,
}

async fn splice(relay: &TestRelay, plan: Option<&str>) -> Splice {
    let mut mac = register_mac(relay, "mac").await;
    let mut phone = connect(relay.signal_port).await;
    send(&mut phone, &connect_request(plan)).await;

    let phone_session = await_session(&mut phone).await;
    let mac_session = await_session(&mut mac).await;

    // Both ends present the same control token. Whichever arrives first waits for the other, and
    // whoever ends up holding both splices, so the first byte is what proves the splice is up
    // rather than assuming it from the two calls returning.
    let mut phone_side = present(relay.control_port, &phone_session.control_token).await;
    let mut mac_side = present(relay.control_port, &mac_session.control_token).await;
    assert!(
        carries_traffic(&mut phone_side, &mut mac_side, b'!').await,
        "the splice should be carrying traffic before a test starts charging for it"
    );

    Splice {
        phone: phone_side,
        mac: mac_side,
        phone_ws: phone,
        _mac_ws: mac,
    }
}

/// Pushes a byte in at one end and reports whether it came out of the other.
///
/// Anything but a delivered byte is a splice that has stopped carrying traffic, which is the only
/// thing the metering tests are asking about: a session the relay has ended and a session whose
/// sockets have gone quiet look the same from here on purpose.
async fn carries_traffic(writer: &mut TcpStream, reader: &mut TcpStream, byte: u8) -> bool {
    if writer.write_all(&[byte]).await.is_err() {
        return false;
    }
    let mut heard = [0u8; 1];
    matches!(
        timeout(PATIENCE, reader.read_exact(&mut heard)).await,
        Ok(Ok(_)) if heard[0] == byte
    )
}

/// Whether the relay has let go of this end, which is what an ended session looks like from a
/// client: the socket closes and the read comes back with nothing in it.
async fn closed(stream: &mut TcpStream) -> bool {
    let mut buf = [0u8; 1];
    loop {
        match timeout(PATIENCE, stream.read(&mut buf)).await {
            // Closed by the relay, or reset by it: both mean the splice is over, and which of the
            // two it was is not something a client can tell a user apart by.
            Ok(Ok(0)) | Ok(Err(_)) => return true,
            // Traffic that is not this test's, which the splice is entitled to carry.
            Ok(Ok(_)) => continue,
            Err(_) => return false,
        }
    }
}

/// A session that runs past its allowance is ended, and coming straight back does not get another.
///
/// **This is the hole the per-charge meter closes.** The allowance used to be looked at once, before
/// the session was allocated, and the counter only moved when a splice finished, so a client with a
/// second of credit could open a splice and hold it open for as long as it liked. The numbers here
/// are small on purpose: two seconds of allowance and a charge every tenth of a second, so the test
/// waits a couple of seconds rather than the fifteen one charge would otherwise take.
#[tokio::test]
async fn a_session_that_runs_past_its_allowance_is_ended() {
    let quota = Arc::new(
        QuotaTracker::new(
            PlanAllowances {
                free_seconds: Some(2),
                relay_seconds: Some(60),
            },
            Default::default(),
        )
        .with_charge_period(Duration::from_millis(100)),
    );
    let relay = start_with(Arc::clone(&quota)).await;
    let mut client = splice(&relay, Some("free")).await;

    assert!(
        closed(&mut client.phone).await,
        "the relay should end a session whose allowance is spent"
    );
    assert_eq!(
        quota.remaining("phone", None, Plan::Free),
        Some(0),
        "and what ended it is the counter, not a connection that happened to drop"
    );

    // The client cannot simply ask again: the seconds it spent are spent, and the check before a
    // session is allocated reads the same counter the meter was charging.
    send(&mut client.phone_ws, &connect_request(Some("free"))).await;
    assert!(
        matches!(
            next_message(&mut client.phone_ws).await,
            ServerMessage::Error { ref code, .. } if code == "quotaExceeded"
        ),
        "a client with nothing left should be told so rather than given a second session"
    );
}

/// A session well inside its allowance is charged for what it runs and left alone.
///
/// The other half of the same rule, and the one a broken relay would show: charging while a splice
/// runs must not disturb a client that is nowhere near its limit. This session is charged several
/// times over, and carries traffic on both sides of those charges.
#[tokio::test]
async fn a_session_inside_its_allowance_is_charged_and_left_alone() {
    let quota = Arc::new(
        QuotaTracker::new(PlanAllowances::default(), Default::default())
            .with_charge_period(Duration::from_millis(100)),
    );
    let relay = start_with(Arc::clone(&quota)).await;
    let mut client = splice(&relay, Some("free")).await;

    // Several charge periods, and a fraction of the hour this client is allowed.
    tokio::time::sleep(Duration::from_millis(600)).await;

    assert!(
        carries_traffic(&mut client.phone, &mut client.mac, b'a').await,
        "a session that is inside its allowance must keep splicing"
    );
    assert!(
        carries_traffic(&mut client.mac, &mut client.phone, b'b').await,
        "and must keep splicing in both directions"
    );

    let left = quota
        .remaining("phone", None, Plan::Free)
        .expect("a free plan is metered");
    assert!(
        left < 60 * 60,
        "the time it ran should have been charged: {left} seconds left"
    );
    assert!(
        left > 60 * 60 - 60,
        "and no more of it than it ran: {left} seconds left"
    );
}

/// An unlimited plan is tracked like everything else and is never ended by the meter.
///
/// The rule the relay has always had, now that something watches the counter while a session runs:
/// Plus and Pro are metered for the log and are not blocked by it. This session outlives the whole
/// of a free allowance by several times over, and is still carrying traffic at the end of it.
#[tokio::test]
async fn an_unlimited_plan_is_never_ended_by_the_meter() {
    let quota = Arc::new(
        QuotaTracker::new(
            PlanAllowances {
                free_seconds: Some(1),
                relay_seconds: Some(1),
            },
            Default::default(),
        )
        .with_charge_period(Duration::from_millis(100)),
    );
    let relay = start_with(Arc::clone(&quota)).await;
    let mut client = splice(&relay, Some("pro")).await;

    // Several times what the free allowance would have bought, and many charge periods.
    tokio::time::sleep(Duration::from_millis(1_500)).await;

    assert!(
        carries_traffic(&mut client.phone, &mut client.mac, b'z').await,
        "a Pro session must not be ended by the counter, however long it runs"
    );
    assert_eq!(
        quota.remaining("phone", None, Plan::Pro),
        None,
        "and it is still not bounded by the counter it was allocated against"
    );

    // That it was *tracked* is what the free plan's number is used for here: it is a ruler, not a
    // limit. Pro is metered for the log the same way free is, so what this session spent shows up
    // in a reading that does not bound it at all.
    let left = quota
        .remaining("phone", None, Plan::Free)
        .expect("a free plan is metered");
    assert!(
        left < 60 * 60 - 1,
        "an unlimited session is still charged for the log: less than a free allowance is left, {left} seconds"
    );
}

/// **A socket that never says hello.** Nothing is authenticated in front of this listener, and
/// before these deadlines existed a peer could open a connection, send nothing at all, and hold a
/// task and a file descriptor for as long as it liked, at any of the three stages, including the
/// WebSocket upgrade this test exercises.
#[tokio::test]
async fn a_socket_that_never_finishes_its_handshake_is_closed() {
    let relay = start_with_timeouts(
        Arc::new(QuotaTracker::new(PlanAllowances::default(), Default::default())),
        Duration::from_millis(250),
        Duration::from_secs(30),
    )
    .await;

    let mut socket = TcpStream::connect(("127.0.0.1", relay.signal_port))
        .await
        .expect("the signalling port should accept a connection");

    // Nothing is written: no TLS, no WebSocket, no bytes. The relay has to give up on its own.
    let mut byte = [0u8; 1];
    let read = timeout(PATIENCE, socket.read(&mut byte)).await;

    assert!(
        matches!(read, Ok(Ok(0)) | Ok(Err(_))),
        "the relay held a socket that never said anything"
    );
}

/// **A connection that has said hello and then gone quiet.** A registered Mac holds its socket open
/// for as long as it is running and pings every 25 seconds, so a *silent* one is a connection that
/// has gone, not one that is resting: the deadline is what makes the difference observable.
#[tokio::test]
async fn a_signalling_connection_that_goes_quiet_is_dropped() {
    let relay = start_with_timeouts(
        Arc::new(QuotaTracker::new(PlanAllowances::default(), Default::default())),
        Duration::from_secs(10),
        // Short enough to watch inside a test, and the point is the deadline rather than the number.
        Duration::from_millis(250),
    )
    .await;

    let mut ws = connect(relay.signal_port).await;

    let closed = timeout(PATIENCE, async {
        loop {
            match ws.next().await {
                // A Close frame, a clean end, or a transport error: all three mean the relay let go.
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => return,
                Some(Ok(_)) => continue,
            }
        }
    })
    .await;

    assert!(closed.is_ok(), "the relay held a silent connection open");
}

/// And a connection that keeps talking is *not* dropped, which is what the deadline is only useful
/// alongside: a Mac that pings on its own schedule stays registered indefinitely.
#[tokio::test]
async fn a_connection_that_keeps_pinging_is_not_dropped() {
    let relay = start_with_timeouts(
        Arc::new(QuotaTracker::new(PlanAllowances::default(), Default::default())),
        Duration::from_secs(10),
        Duration::from_millis(250),
    )
    .await;

    let mut ws = connect(relay.signal_port).await;

    // Four times the idle deadline, pinged twice as often as it expires.
    for _ in 0..8 {
        tokio::time::sleep(Duration::from_millis(125)).await;
        send(&mut ws, &ClientMessage::Ping).await;
        let mut answered = false;
        while !answered {
            match timeout(PATIENCE, ws.next()).await {
                Ok(Some(Ok(Message::Text(_)))) => answered = true,
                Ok(Some(Ok(_))) => continue,
                other => panic!("the relay dropped a connection that was pinging: {other:?}"),
            }
        }
    }
}

// MARK: - What the allowance hangs from

/// A client key and the proof it makes over its own device id.
///
/// Built here the way the app builds it: a P-256 key, the 65-byte uncompressed point in hex, and a
/// DER signature over `device_proof::client_payload`. The point of exercising it end to end is that
/// the two sides of this signature are written in two languages, and a payload spelled differently
/// in each is a proof that never verifies and looks, from the relay, exactly like a client that did
/// not send one.
fn client_proof(
    signing: &p256::ecdsa::SigningKey,
    client_id: &str,
    proof_time: u64,
) -> (String, String, u64) {
    use p256::ecdsa::{Signature, signature::Signer};

    let body = peeringd::device_proof::client_payload(client_id, proof_time);
    let signature: Signature = signing.sign(body.as_bytes());
    (
        peeringd::protocol::bytes_hex(&signing.verifying_key().to_sec1_bytes()),
        peeringd::protocol::bytes_hex(signature.to_der().as_bytes()),
        proof_time,
    )
}

/// **The reinstall, which is what this whole proof is for.** A device id lives in the app's own
/// storage and is destroyed by deleting the app; the key lives in the Keychain, and iOS keeps those
/// through a reinstall. So the second install announces a *different* id and signs with the *same*
/// key, and what it has already spent has to follow the key rather than the id.
#[tokio::test]
async fn a_reinstall_spends_the_allowance_the_first_install_spent() {
    use p256::ecdsa::SigningKey;

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();

    // One second of free relay. A splice is charged a minimum of one second, so a session that
    // runs for any fraction of a second spends the whole allowance and the test does not have to
    // sit here for two seconds to watch a counter move.
    let quota = Arc::new(
        QuotaTracker::new(
            PlanAllowances {
                free_seconds: Some(1),
                relay_seconds: Some(10_800),
            },
            Default::default(),
        )
        .with_charge_period(Duration::from_millis(100)),
    );
    let relay = start_with(Arc::clone(&quota)).await;
    let mut mac = register_mac(&relay, "mac").await;

    // The key this phone holds, and the id its first install announced.
    let signing = SigningKey::from_bytes(&[0x42; 32].into()).expect("a valid scalar");
    let first = client_proof(&signing, "install-one", now);

    let mut phone = connect(relay.signal_port).await;
    send(
        &mut phone,
        &ClientMessage::ConnectToHost {
            host_id: "mac".into(),
            client_id: "install-one".into(),
            protocol_version: 3,
            api_key: None,
            plan: Some("free".into()),
            jws_representation: None,
            public_key: Some(first.0.clone()),
            proof: Some(first.1),
            proof_time: Some(first.2),
        },
    )
    .await;

    let phone_session = await_session(&mut phone).await;
    let mac_session = await_session(&mut mac).await;
    let mut phone_side = present(relay.control_port, &phone_session.control_token).await;
    let mut mac_side = present(relay.control_port, &mac_session.control_token).await;
    assert!(carries_traffic(&mut phone_side, &mut mac_side, b'!').await);

    // Long enough to spend the two seconds several times over.
    tokio::time::sleep(Duration::from_millis(600)).await;

    assert_eq!(
        quota.remaining(&first.0, None, Plan::Free),
        Some(0),
        "the key is what the relay charged, and it is spent"
    );

    // And the second install: a fresh id, the same key, nothing left.
    let mut reinstalled = connect(relay.signal_port).await;
    let second = client_proof(&signing, "install-two", now);
    send(
        &mut reinstalled,
        &ClientMessage::ConnectToHost {
            host_id: "mac".into(),
            client_id: "install-two".into(),
            protocol_version: 3,
            api_key: None,
            plan: Some("free".into()),
            jws_representation: None,
            public_key: Some(second.0),
            proof: Some(second.1),
            proof_time: Some(second.2),
        },
    )
    .await;

    assert!(
        matches!(
            next_message(&mut reinstalled).await,
            ServerMessage::Error { ref code, .. } if code == "quotaExceeded"
        ),
        "a fresh id with the same key must not be a fresh allowance"
    );
}

/// And a client that sends no proof is metered by its id, exactly as every build before this one
/// was: the field is optional, and its absence is not a refusal.
#[tokio::test]
async fn a_client_without_a_proof_is_still_metered_by_its_id() {
    let quota = Arc::new(
        QuotaTracker::new(
            PlanAllowances {
                free_seconds: Some(1),
                relay_seconds: Some(10_800),
            },
            Default::default(),
        )
        .with_charge_period(Duration::from_millis(100)),
    );
    let relay = start_with(Arc::clone(&quota)).await;
    let mut client = splice(&relay, Some("free")).await;

    tokio::time::sleep(Duration::from_millis(400)).await;

    assert_eq!(
        quota.remaining("phone", None, Plan::Free),
        Some(0),
        "the announced id is the key when there is no proof"
    );
    let _ = client.phone_ws.send(Message::Close(None)).await;
}
