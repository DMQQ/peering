//! The relayed UDP lane of a session. Loopback sockets stand in for the relay and the client: the scripted relay strips the
//! token the way the real relay does, so the host's datagrams reach the client as the client's opener reads them.

mod support;

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use peering_core::ports::capture::RawFrame;
use peering_core::ports::clock::Clock;
use peering_host::runtime::{PeerInfo, VideoEndpoint};
use peering_wire::chunks::{Reassembler, MAX_REASSEMBLED};
use peering_wire::framing::{Frame, MessageKind};
use peering_wire::handshake::{VideoKeyGrant, VideoTransportKind, VideoTransportRequest};
use peering_wire::relay_messages::{RelayClientMessage, Token};
use peering_wire::sealing::{Direction, Opener, Sealer};
use support::*;
use tokio::net::UdpSocket;
use tokio::task::spawn_local;
use tokio::time::timeout;

const TOKEN: [u8; 16] = [0x5a; 16];
const WAIT: Duration = Duration::from_secs(5);

/// The host's address as the relay learned it from the bind.
type HostAddress = Arc<Mutex<Option<SocketAddr>>>;

/// Forwards like the relay: the host's bind is a token alone and is forwarded nowhere; the token is removed from what the
/// host sends to the client and from what the client sends to the host.
async fn scripted_relay(relay: UdpSocket, client: SocketAddr, host: HostAddress) {
    let mut buffer = vec![0u8; 4096];
    loop {
        let Ok((count, source)) = relay.recv_from(&mut buffer).await else {
            continue;
        };
        if source == client {
            let to = *host.lock().expect("the host address is not poisoned");
            if let Some(to) = to.filter(|_| count > TOKEN.len()) {
                let _forwarded = relay.send_to(&buffer[TOKEN.len()..count], to).await;
            }
        } else if count == TOKEN.len() {
            *host.lock().expect("the host address is not poisoned") = Some(source);
        } else {
            let _forwarded = relay.send_to(&buffer[TOKEN.len()..count], client).await;
        }
    }
}

/// The client end: one socket, the host-to-client opener, and the client-to-host sealer for the granted key.
struct Client {
    socket: UdpSocket,
    relay: SocketAddr,
    host: HostAddress,
    opener: Opener,
    sealer: Sealer,
    reassembler: Reassembler,
}

impl Client {
    fn new(socket: UdpSocket, relay: SocketAddr, host: HostAddress, secret: &[u8]) -> Client {
        Client {
            socket,
            relay,
            host,
            opener: Opener::new(secret, Direction::HostToClient).expect("the granted key opens host datagrams"),
            sealer: Sealer::new(secret, Direction::ClientToHost, TOKEN).expect("the granted key seals client datagrams"),
            reassembler: Reassembler::new(MAX_REASSEMBLED),
        }
    }

    /// The next whole message the host sent, and the address it came from.
    async fn next_message(&mut self) -> (Frame, SocketAddr) {
        let mut buffer = vec![0u8; 4096];
        loop {
            let (count, source) = timeout(WAIT, self.socket.recv_from(&mut buffer))
                .await
                .expect("the host sends within five seconds")
                .expect("the client socket reads");
            let Some(frame) = self.opener.open(&buffer[..count]).expect("host datagrams authenticate") else {
                continue;
            };
            let whole = if frame.kind == MessageKind::VideoChunk {
                self.reassembler.ingest(&frame).expect("the chunks are well formed")
            } else {
                Some(frame)
            };
            if let Some(whole) = whole {
                return (whole, source);
            }
        }
    }

    async fn next_of_kind(&mut self, kind: MessageKind) -> (Frame, SocketAddr) {
        loop {
            let message = self.next_message().await;
            if message.0.kind == kind {
                return message;
            }
        }
    }

    /// Sends one message through the relay, as the phone does: sealed with the token in front.
    async fn send_relayed(&mut self, kind: MessageKind, payload: &[u8]) {
        for datagram in self.sealer.seal(kind, payload) {
            self.socket.send_to(&datagram, self.relay).await.expect("the relay socket takes the datagram");
        }
    }

    /// Sends one message straight to the host, as the phone does once the direct path has opened: no token.
    async fn send_direct(&mut self, kind: MessageKind, payload: &[u8]) {
        let host = self.host_address();
        for datagram in self.sealer.seal(kind, payload) {
            self.socket.send_to(&datagram[TOKEN.len()..], host).await.expect("the host socket takes the datagram");
        }
    }

    fn host_address(&self) -> SocketAddr {
        self.host.lock().expect("the host address is not poisoned").expect("the host has bound through the relay")
    }
}

/// Starts the scripted relay and the client socket, and returns what the test needs to address them.
async fn rig() -> (SocketAddr, SocketAddr, UdpSocket, HostAddress) {
    let relay = UdpSocket::bind("127.0.0.1:0").await.expect("a loopback socket binds");
    let client = UdpSocket::bind("127.0.0.1:0").await.expect("a loopback socket binds");
    let relay_address = relay.local_addr().expect("the relay has an address");
    let client_address = client.local_addr().expect("the client has an address");
    let host: HostAddress = Arc::new(Mutex::new(None));
    spawn_local(scripted_relay(relay, client_address, host.clone()));
    (relay_address, client_address, client, host)
}

/// Pairs over the relay, selects the display and asks for the lane's key. Returns the phone and the granted secret.
async fn relayed_session(harness: &Harness, relay: SocketAddr) -> (Phone, Vec<u8>) {
    let peer = PeerInfo {
        via_relay: true,
        video_token: Some(TOKEN),
        video_endpoint: Some(VideoEndpoint { host: "127.0.0.1".to_owned(), port: relay.port() }),
        ..direct_peer()
    };
    let (mut phone, result, _offer) = pair_with_peer(&harness.runtime, peer, |client, secret| client.proof(secret)).await;
    assert!(result.accepted, "the relayed pairing is accepted");
    phone.send_command(&select_display_command()).await;
    phone.send(Frame::empty(MessageKind::VideoKeyRequest)).await;
    let grant: VideoKeyGrant = decode_json(&phone.next_of(MessageKind::VideoKey).await);
    (phone, grant.secret)
}

fn picture(harness: &Harness, sequence: u64) {
    harness.capture.lock().expect("the capture is not poisoned").push_frame(RawFrame { width: 1280, height: 720, sequence });
    harness.runtime.pump_video(harness.clock.now_seconds()).expect("the pump runs");
}

async fn request_transport(phone: &mut Phone, transport: VideoTransportKind) {
    let request = VideoTransportRequest { transport, reason: "test".to_owned() };
    phone.send_json(MessageKind::VideoTransport, &request).await;
}

#[test]
fn a_relayed_client_receives_the_picture_as_sealed_datagrams_from_the_relay() {
    run(async {
        let (relay, _client_address, socket, host) = rig().await;
        let harness = harness();
        let (_phone, secret) = relayed_session(&harness, relay).await;
        let mut client = Client::new(socket, relay, host, &secret);
        picture(&harness, 1);
        let (config, from) = client.next_message().await;
        assert_eq!(config.kind, MessageKind::VideoConfig);
        assert_eq!(from, relay);
        let (picture, _) = client.next_message().await;
        assert_eq!(picture.kind, MessageKind::VideoFrame);
    });
}

#[test]
fn a_ping_on_the_relayed_lane_is_answered_with_a_pong_on_the_same_path() {
    run(async {
        let (relay, _client_address, socket, host) = rig().await;
        let harness = harness();
        let (_phone, secret) = relayed_session(&harness, relay).await;
        let mut client = Client::new(socket, relay, host, &secret);
        client.send_relayed(MessageKind::Ping, b"lat").await;
        let (pong, from) = client.next_message().await;
        assert_eq!(pong.kind, MessageKind::Pong);
        assert_eq!(pong.payload, b"lat");
        assert_eq!(from, relay);
    });
}

#[test]
fn a_fallback_request_moves_the_picture_to_the_control_connection_and_back() {
    run(async {
        let (relay, _client_address, socket, host) = rig().await;
        let harness = harness();
        let (mut phone, secret) = relayed_session(&harness, relay).await;
        let mut client = Client::new(socket, relay, host, &secret);
        picture(&harness, 1);
        client.next_message().await;
        client.next_message().await;

        request_transport(&mut phone, VideoTransportKind::Control).await;
        phone.sync().await;
        picture(&harness, 2);
        let on_control = phone.next_of(MessageKind::VideoFrame).await;
        assert!(!on_control.payload.is_empty(), "the picture arrives on the control connection");

        request_transport(&mut phone, VideoTransportKind::Primary).await;
        phone.sync().await;
        picture(&harness, 3);
        let (returned, from) = client.next_message().await;
        assert_eq!(returned.kind, MessageKind::VideoFrame);
        assert_eq!(from, relay);
    });
}

#[test]
fn a_direct_probe_that_authenticates_moves_the_picture_to_the_clients_own_address() {
    run(async {
        let (relay, client_address, socket, host) = rig().await;
        let harness = harness();
        let mut asks = harness.runtime.attach_signalling();
        let (_phone, secret) = relayed_session(&harness, relay).await;
        let mut client = Client::new(socket, relay, host, &secret);

        let ask = timeout(WAIT, asks.recv()).await.expect("the lane asks where the client is");
        assert_eq!(ask, Some(RelayClientMessage::RequestPeerAddress { video_token: Token(TOKEN).to_hex() }));
        harness.runtime.answer_peer_address("127.0.0.1", client_address.port());

        // The knock is scheduled on the fake clock, so the clock moves until the host's probe arrives at the client.
        let (probe, from) = loop {
            harness.clock.advance(0.5);
            if let Ok(message) = timeout(Duration::from_millis(200), client.next_of_kind(MessageKind::DirectProbe)).await {
                break message;
            }
        };
        assert_eq!(probe.kind, MessageKind::DirectProbe);
        assert_eq!(from, client.host_address());

        client.send_direct(MessageKind::DirectProbe, &[]).await;
        client.send_direct(MessageKind::Ping, b"direct").await;
        let (pong, from) = client.next_of_kind(MessageKind::Pong).await;
        assert_eq!(pong.payload, b"direct");
        assert_eq!(from, client.host_address());

        picture(&harness, 1);
        let (config, from) = client.next_of_kind(MessageKind::VideoConfig).await;
        assert_eq!(config.kind, MessageKind::VideoConfig);
        assert_eq!(from, client.host_address());
    });
}
