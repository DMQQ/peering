//! Keeps the host registered with the relay over a WebSocket, and dials the relay's control port when it announces a
//! session. The registration state machine decides what to send and when to reconnect; this file only moves bytes.

use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use peering_core::relay::dial::{first_bytes, plan as dial_plan, DialPlan};
use peering_core::relay::registration::{RegAction, RelayRegistration, RelaySession};
use peering_net::tls::HostTls;
use peering_wire::relay_messages::{encode_sorted, RelayServerMessage};
use peering_wire::relay_proof::ProofSigner;
use rustls::crypto::ring::default_provider;
use rustls::{ClientConfig, RootCertStore};
use tokio::io::AsyncWriteExt;
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio::task::spawn_local;
use tokio::time::interval;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{connect_async_tls_with_config, Connector, MaybeTlsStream, WebSocketStream};

use super::connection::serve;
use super::control::RelayStatus;
use super::peer_address::peer_socket_addr;
use super::shared::Shared;
use super::{HostProfile, PeerInfo, RelayConfig, VideoEndpoint};

const PROTOCOL_VERSION: u16 = peering_core::session::handshake::PROTOCOL_VERSION;
const TICK: Duration = Duration::from_secs(1);

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

pub async fn run(shared: Shared, profile: Arc<HostProfile>, tls: Arc<HostTls>, relay: RelayConfig, signer: Box<dyn ProofSigner>) {
    let mut registration = RelayRegistration::new(relay.device_id.clone(), relay.name.clone(), PROTOCOL_VERSION, signer);
    // The first connection waits one backoff step like a reconnect does, so a relay that is down at launch is not hammered.
    registration.on_disconnect(profile.clock.as_ref());
    let mut ticks = interval(TICK);
    loop {
        ticks.tick().await;
        let actions = registration.tick(profile.clock.as_ref());
        if !actions.contains(&RegAction::Connect) {
            continue;
        }
        set_relay_status(&shared, RelayStatus::Connecting);
        let Ok(mut socket) = connect(&relay.url).await else {
            set_relay_status(&shared, RelayStatus::Retrying);
            registration.on_disconnect(profile.clock.as_ref());
            continue;
        };
        let mut pending = registration.start(profile.clock.as_ref());
        let (asks_tx, mut asks) = mpsc::unbounded_channel();
        shared.peer_addresses().attach(Some(asks_tx));
        loop {
            if apply(&mut socket, &mut pending, &shared, &profile, &tls).await.is_break() {
                break;
            }
            tokio::select! {
                message = socket.next() => match message {
                    Some(Ok(Message::Text(text))) => match serde_json::from_str::<RelayServerMessage>(&text) {
                        Ok(message) => {
                            if answer_ask(&shared, &message) {
                                continue;
                            }
                            pending = registration.on_message(message, profile.clock.as_ref());
                            if registration.is_registered() {
                                set_relay_status(&shared, RelayStatus::Registered);
                            }
                        }
                        Err(_) => continue,
                    },
                    Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                    Some(Ok(_)) => continue,
                },
                Some(ask) = asks.recv() => {
                    if socket.send(Message::Text(encode_sorted(&ask).into())).await.is_err() {
                        break;
                    }
                }
                _ = ticks.tick() => pending = registration.tick(profile.clock.as_ref()),
            }
        }
        shared.peer_addresses().attach(None);
        set_relay_status(&shared, RelayStatus::Retrying);
        registration.on_disconnect(profile.clock.as_ref());
    }
}

fn set_relay_status(shared: &Shared, status: RelayStatus) {
    shared.lock().relay = status;
}

/// Hands the relay's answer to a video lane's `requestPeerAddress` to that lane. Returns true when the message was such an
/// answer, which must not reach the registration: the registration treats any error as a reason to disconnect.
fn answer_ask(shared: &Shared, message: &RelayServerMessage) -> bool {
    match message {
        RelayServerMessage::PeerAddress { host, port } => {
            if let Some(address) = peer_socket_addr(host, *port) {
                shared.peer_addresses().answer(address);
            }
            true
        }
        RelayServerMessage::Error { code, .. } if code == "peerAddressUnknown" => {
            shared.peer_addresses().refuse();
            true
        }
        _ => false,
    }
}

/// Applies the registration's actions. Returns `Break` when the socket must be closed.
async fn apply(
    socket: &mut Socket,
    actions: &mut Vec<RegAction>,
    shared: &Shared,
    profile: &Arc<HostProfile>,
    tls: &Arc<HostTls>,
) -> std::ops::ControlFlow<()> {
    for action in std::mem::take(actions) {
        match action {
            RegAction::Send(message) => {
                if socket.send(Message::Text(encode_sorted(&message).into())).await.is_err() {
                    return std::ops::ControlFlow::Break(());
                }
            }
            RegAction::DialSession(session) => {
                spawn_local(dial(shared.clone(), profile.clone(), tls.clone(), session));
            }
            RegAction::Close => return std::ops::ControlFlow::Break(()),
            RegAction::Connect => {}
        }
    }
    std::ops::ControlFlow::Continue(())
}

async fn connect(url: &str) -> Result<Socket, Box<dyn std::error::Error + Send + Sync>> {
    let mut roots = RootCertStore::empty();
    roots.roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let config = ClientConfig::builder_with_provider(Arc::new(default_provider()))
        .with_safe_default_protocol_versions()?
        .with_root_certificates(roots)
        .with_no_client_auth();
    let (socket, _response) =
        connect_async_tls_with_config(url, None, false, Some(Connector::Rustls(Arc::new(config)))).await?;
    Ok(socket)
}

/// Writes the session token, then serves the connection as the relay's client side. A plan the relay should not have
/// sent is dropped; the registration stays up.
async fn dial(shared: Shared, profile: Arc<HostProfile>, tls: Arc<HostTls>, session: RelaySession) {
    let Ok(plan): Result<DialPlan, _> = dial_plan(&session) else {
        return;
    };
    let Ok(mut tcp) = TcpStream::connect((plan.host.as_str(), plan.port)).await else {
        return;
    };
    if tcp.write_all(&first_bytes(&plan)).await.is_err() {
        return;
    }
    let Ok(accepted) = tls.relay_accept(tcp).await else {
        return;
    };
    let peer = PeerInfo {
        public_key: Some(accepted.client_public_key),
        via_relay: true,
        video_token: Some(session.video_token.0),
        video_endpoint: Some(VideoEndpoint { host: session.video_host.clone(), port: session.video_port }),
    };
    serve(shared, profile, accepted.stream, peer).await;
}
