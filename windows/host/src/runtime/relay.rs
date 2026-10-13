//! Keeps the host registered with the relay over a WebSocket, and dials the relay's control port when it announces a
//! session. The registration state machine decides what to send and when to reconnect; this file only moves bytes.

use std::sync::Arc;
use std::time::Duration;

use std::panic::AssertUnwindSafe;

use futures_util::{FutureExt, SinkExt, StreamExt};
use peering_core::ports::clock::Clock;
use peering_core::relay::dial::{first_bytes, plan as dial_plan, DialPlan};
use peering_core::relay::registration::{RegAction, RelayFault, RelayRegistration, RelaySession};
use peering_core::video::recovery::LogGate;
use peering_net::tls::HostTls;
use peering_wire::relay_messages::encode_sorted;
use peering_wire::relay_proof::ProofSigner;
use rustls::crypto::ring::default_provider;
use rustls::{ClientConfig, RootCertStore};
use tokio::io::AsyncWriteExt;
use tokio::net::TcpStream;
use tokio::task::spawn_local;
use tokio::time::{interval, timeout, Interval};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{connect_async_tls_with_config, Connector, MaybeTlsStream, WebSocketStream};

mod incoming;

use incoming::{on_socket_message, Incoming};

use super::connection::serve_counted;
use super::control::RelayStatus;
use super::diagnostics;
use super::peer_address::signalling_channel;
use super::pre_auth::{PreAuthGate, PreAuthPermit};
use super::problem_source::ProblemSource;
use super::random::unit_fraction;
use super::shared::Shared;
use super::{HostProfile, PeerInfo, RelayConfig, VideoEndpoint};

const PROTOCOL_VERSION: u16 = peering_core::session::handshake::PROTOCOL_VERSION;
const TICK: Duration = Duration::from_secs(1);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
const SEND_TIMEOUT: Duration = Duration::from_secs(10);
const DIAL_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const DIAL_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const MAXIMUM_CONCURRENT_DIALS: usize = 8;

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

pub async fn run(shared: Shared, profile: Arc<HostProfile>, tls: Arc<HostTls>, relay: RelayConfig, signer: Box<dyn ProofSigner>) {
    let mut registration = RelayRegistration::new(relay.device_id.clone(), relay.name.clone(), PROTOCOL_VERSION, signer)
        .with_jitter(Box::new(unit_fraction));
    // The first connection waits one backoff step like a reconnect does, so a relay that is down at launch is not hammered.
    registration.on_disconnect(profile.clock.as_ref());
    let dials = PreAuthGate::new(MAXIMUM_CONCURRENT_DIALS);
    let mut ticks = interval(TICK);
    let mut panics = LogGate::default();
    loop {
        ticks.tick().await;
        let actions = registration.tick(profile.clock.as_ref());
        if !actions.contains(&RegAction::Connect) {
            continue;
        }
        let dialer = Dialer { shared: &shared, profile: &profile, tls: &tls, dials: &dials };
        let pass = AssertUnwindSafe(serve_connection(&relay, &mut registration, dialer, &mut ticks)).catch_unwind().await;
        if let Err(payload) = pass {
            // A panic in one connection must not end remote access for the rest of the run.
            shared.peer_addresses().attach(None);
            registration.on_disconnect(profile.clock.as_ref());
            set_relay_status(&shared, RelayStatus::Retrying);
            if panics.allow(profile.clock.now_seconds()).is_some() {
                diagnostics::log(&format!("the relay connection panicked: {}", panic_text(payload.as_ref())));
            }
        }
    }
}

/// One connection to the relay, from the dial to the socket closing. The registration is told of the disconnect.
async fn serve_connection(
    relay: &RelayConfig,
    registration: &mut RelayRegistration,
    dialer: Dialer<'_>,
    ticks: &mut Interval,
) {
    let Dialer { shared, profile, tls, dials } = dialer;
    let clock = profile.clock.as_ref();
    let Some(mut socket) = open_socket(relay, registration, shared, clock).await else {
        return;
    };
    let mut pending = registration.start(clock);
    let (asks_tx, mut asks) = signalling_channel();
    shared.peer_addresses().attach(Some(asks_tx));
    loop {
        if apply(&mut socket, &mut pending, Dialer { shared, profile, tls, dials }).await.is_break() {
            break;
        }
        tokio::select! {
            message = socket.next() => match on_socket_message(message, registration, shared, clock) {
                Incoming::Closed => break,
                Incoming::Actions(actions) => pending = actions,
                Incoming::Nothing => {}
            },
            Some(ask) = asks.recv() => {
                if send_message(&mut socket, &ask).await.is_err() {
                    break;
                }
            }
            _ = ticks.tick() => {
                pending = registration.tick(clock);
                if registration.is_registered() && send_notifications(&mut socket, shared).await.is_err() {
                    break;
                }
            }
        }
    }
    close_link(registration, shared, clock);
}

/// The socket is gone: the lanes lose their signalling, the registration learns of it, and the window shows why.
fn close_link(registration: &mut RelayRegistration, shared: &Shared, clock: &dyn Clock) {
    shared.peer_addresses().attach(None);
    registration.on_disconnect(clock);
    report_link_down(shared, registration.fault());
}

/// Dials the relay. A relay that does not answer in time is a disconnect for the registration, to be retried by its ladder.
async fn open_socket(relay: &RelayConfig, registration: &mut RelayRegistration, shared: &Shared, clock: &dyn Clock) -> Option<Socket> {
    set_relay_status(shared, RelayStatus::Connecting);
    match timeout(CONNECT_TIMEOUT, connect(&relay.url)).await {
        Ok(Ok(socket)) => Some(socket),
        Ok(Err(_)) | Err(_) => {
            set_relay_status(shared, RelayStatus::Retrying);
            registration.on_disconnect(clock);
            None
        }
    }
}

/// The relay is not reachable for now. A clock the relay refuses gets its own status and a sentence that says what to do,
/// because retrying cannot fix it.
fn report_link_down(shared: &Shared, fault: Option<RelayFault>) {
    let mut state = shared.lock();
    match fault {
        Some(RelayFault::ClockSkew) => {
            state.relay = RelayStatus::ClockSkew;
            state.set_problem(ProblemSource::RelayClock, crate::strings::RELAY_CLOCK_SKEW_PROBLEM.to_owned());
        }
        None => state.relay = RelayStatus::Retrying,
    }
}

fn panic_text(payload: &(dyn std::any::Any + Send)) -> String {
    payload
        .downcast_ref::<&str>()
        .map(|text| (*text).to_owned())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "no message".to_owned())
}

/// Sends the push notifications waiting for the relay, each leaving the queue only once the socket took it.
async fn send_notifications(socket: &mut Socket, shared: &Shared) -> Result<(), ()> {
    loop {
        let Some(message) = shared.lock().notifications.next() else {
            return Ok(());
        };
        send_message(socket, &message).await?;
        shared.lock().notifications.sent(&message);
    }
}

/// A relay that stops reading would otherwise hold the registration loop, and with it the reconnect and the ping.
async fn send_message<M: serde::Serialize>(socket: &mut Socket, message: &M) -> Result<(), ()> {
    match timeout(SEND_TIMEOUT, socket.send(Message::Text(encode_sorted(message).into()))).await {
        Ok(Ok(())) => Ok(()),
        Ok(Err(_)) | Err(_) => Err(()),
    }
}

fn set_relay_status(shared: &Shared, status: RelayStatus) {
    shared.lock().relay = status;
}

/// What a dial to the relay's control port needs, and the cap on how many run at once.
struct Dialer<'a> {
    shared: &'a Shared,
    profile: &'a Arc<HostProfile>,
    tls: &'a Arc<HostTls>,
    dials: &'a PreAuthGate,
}

/// Applies the registration's actions. Returns `Break` when the socket must be closed.
async fn apply(socket: &mut Socket, actions: &mut Vec<RegAction>, dialer: Dialer<'_>) -> std::ops::ControlFlow<()> {
    for action in std::mem::take(actions) {
        match action {
            RegAction::Send(message) => {
                if send_message(socket, &message).await.is_err() {
                    return std::ops::ControlFlow::Break(());
                }
            }
            RegAction::DialSession(session) => {
                // A session the cap turns away is not answered; the relay's own timeout ends it.
                if let Some(permit) = dialer.dials.enter() {
                    spawn_local(dial(dialer.shared.clone(), dialer.profile.clone(), dialer.tls.clone(), session, permit));
                }
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
async fn dial(shared: Shared, profile: Arc<HostProfile>, tls: Arc<HostTls>, session: RelaySession, permit: PreAuthPermit) {
    let Ok(plan): Result<DialPlan, _> = dial_plan(&session) else {
        return;
    };
    let Ok(Ok(mut tcp)) = timeout(DIAL_CONNECT_TIMEOUT, TcpStream::connect((plan.host.as_str(), plan.port))).await else {
        return;
    };
    // Only latency suffers when the option cannot be set, so the connection is still served.
    let _nagle = peering_net::socket::disable_nagle(&tcp);
    let _keepalive = peering_net::socket::enable_keepalive(&tcp);
    let Ok(Ok(())) = timeout(DIAL_CONNECT_TIMEOUT, tcp.write_all(&first_bytes(&plan))).await else {
        return;
    };
    let Ok(Ok(accepted)) = timeout(DIAL_HANDSHAKE_TIMEOUT, tls.relay_accept(tcp)).await else {
        return;
    };
    let peer = PeerInfo {
        public_key: Some(accepted.client_public_key),
        address: None,
        via_relay: true,
        video_token: Some(session.video_token.0),
        video_endpoint: Some(VideoEndpoint { host: session.video_host.clone(), port: session.video_port }),
    };
    serve_counted(shared, profile, accepted.stream, peer, Some(permit)).await;
}
