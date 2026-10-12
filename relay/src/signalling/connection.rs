//! One signalling connection: the WebSocket upgrade and the loop that answers its messages.

use std::net::IpAddr;
use std::sync::Arc;
use std::time::Duration;

use futures_util::stream::SplitSink;
use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::mpsc;
use tokio::time;
use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::WebSocketStream;
use tracing::{debug, info, warn};

use super::{dispatch, ConnectionState, HostRegistry, Settings};
use crate::activity;
use crate::client_ip::{forwarded_address, is_loopback};
use crate::protocol::{ClientMessage, ServerMessage};
use crate::redact::tag;
use crate::session::Registry;
use crate::stats::{ActivityOutcome, Refusal, TALLY};

/// The biggest valid message is a `ConnectToHost` carrying a receipt, a few kilobytes (see
/// `storekit::MAX_JWS_BYTES`); this closes a garbage sender before it allocates much.
const MAX_MESSAGE_BYTES: usize = 64 * 1024;

/// The services one connection's messages are answered with.
struct Connection<'a> {
    registry: &'a Arc<Registry>,
    hosts: &'a HostRegistry,
    settings: &'a Settings,
    relay_host: &'a str,
}

/// The WebSocket handshake, plus the client address a loopback proxy named in its headers.
#[allow(clippy::result_large_err)] // the handshake callback's error type is tungstenite's
async fn upgrade<S>(
    stream: S,
    peer: Option<IpAddr>,
    settings: &Settings,
) -> Option<(WebSocketStream<S>, Option<IpAddr>)>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let mut config = WebSocketConfig::default();
    config.max_message_size = Some(MAX_MESSAGE_BYTES);
    config.max_frame_size = Some(MAX_MESSAGE_BYTES);
    let named: Arc<std::sync::Mutex<Option<IpAddr>>> = Arc::default();
    let record = Arc::clone(&named);
    let header = settings.limiter.client_header();
    let limiter = Arc::clone(&settings.limiter);
    let callback = move |request: &Request, response: Response| {
        let forwarded = peer.and_then(|peer| forwarded_address(peer, request.headers(), header));
        if let Some(ip) = forwarded {
            *record.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(ip);
        } else if peer.is_some_and(is_loopback) && limiter.first_headerless_loopback() {
            warn!(header = ?header, "a loopback connection carried no usable client address header; per-address limits do nothing until the proxy sets it");
        }
        Ok(response)
    };
    // Bounded like the TLS handshake: a peer that arrives and says nothing must not hold a task.
    let accepted = time::timeout(
        settings.handshake_timeout,
        tokio_tungstenite::accept_hdr_async_with_config(stream, callback, Some(config)),
    )
    .await;
    match accepted {
        Ok(Ok(ws)) => {
            let forwarded = named.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
            Some((ws, forwarded))
        }
        Ok(Err(error)) => {
            debug!(%error, "websocket handshake failed");
            None
        }
        Err(_) => {
            debug!("websocket handshake timed out");
            None
        }
    }
}

pub(super) async fn handle<S>(
    stream: S,
    peer: Option<IpAddr>,
    relay_host: String,
    registry: Arc<Registry>,
    hosts: HostRegistry,
    settings: Settings,
) where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let Some((ws, forwarded)) = upgrade(stream, peer, &settings).await else { return };

    // Behind a local reverse proxy the socket peer is loopback and the client's own limits are
    // taken here, once the upgrade has said who it is.
    let _forwarded_slot = match forwarded {
        Some(ip) => match settings.limiter.admit_signalling(ip) {
            Some(slot) => Some(slot),
            None => {
                TALLY.refused(Refusal::PerIpLimit);
                debug!("refused a forwarded signalling connection: this address is at its limit");
                return;
            }
        },
        None => None,
    };

    // Every outgoing message goes through this queue, replies included, so the loop owns the sink.
    let (tx, rx) = mpsc::channel::<ServerMessage>(32);
    let mut state = ConnectionState { peer: forwarded.or(peer), ..ConnectionState::default() };
    let connection = Connection { registry: &registry, hosts: &hosts, settings: &settings, relay_host: &relay_host };
    run_connection(ws, &tx, rx, &connection, &mut state).await;

    if let Some(device_id) = state.registered_as {
        hosts.remove_if_ours(&device_id, &tx).await;
        info!(device_id = %tag(&device_id), "host went offline");
    }
}

/// The idle deadline resets on every frame in either direction. A registered Mac is silent between
/// its 25 second pings, so the default is three times that and means the connection has gone.
async fn run_connection<S>(
    ws: WebSocketStream<S>,
    tx: &mpsc::Sender<ServerMessage>,
    mut rx: mpsc::Receiver<ServerMessage>,
    connection: &Connection<'_>,
    state: &mut ConnectionState,
) where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (mut sink, mut source) = ws.split();
    let idle = connection.settings.idle_timeout;
    let mut deadline = Box::pin(time::sleep(idle));

    loop {
        // Biased, deadline first and writer before reader, so a peer that keeps the reader ready
        // cannot starve the clock or the queue of replies.
        tokio::select! {
            biased;
            _ = &mut deadline => {
                debug!("signalling connection has been idle for too long");
                break;
            }
            outgoing = rx.recv() => {
                deadline.as_mut().reset(time::Instant::now() + idle);
                let Some(message) = outgoing else { break };
                if !send_to_peer(&mut sink, &message, connection.settings.handshake_timeout).await {
                    break;
                }
            }
            incoming = source.next() => {
                deadline.as_mut().reset(time::Instant::now() + idle);
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        if let Some(reply) = answer(&text, tx, connection, state).await {
                            // Never awaited: this loop is the only reader of the queue, so waiting
                            // on a full one would wait on itself.
                            if tx.try_send(reply).is_err() {
                                debug!("signalling reply queue is full; dropping the peer");
                                break;
                            }
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => break,
                    // Ping, Pong and Binary are not part of this conversation.
                    Some(Ok(_)) => {}
                    Some(Err(error)) => {
                        debug!(%error, "signalling read failed");
                        break;
                    }
                }
            }
        }
    }
}

/// Writes one message, bounded like the handshake. False means the peer is gone or stopped reading.
async fn send_to_peer<S>(
    sink: &mut SplitSink<WebSocketStream<S>, Message>,
    message: &ServerMessage,
    write_timeout: Duration,
) -> bool
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let Ok(json) = serde_json::to_string(message) else { return true };
    match time::timeout(write_timeout, sink.send(Message::Text(json.into()))).await {
        Ok(Ok(())) => true,
        Ok(Err(_)) => false,
        Err(_) => {
            debug!("signalling peer stopped reading; dropping it");
            false
        }
    }
}

/// The reply to one text frame. A message that does not decode is a client on another version,
/// except a `notifyActivity`, which is told which push failed.
async fn answer(
    text: &str,
    tx: &mpsc::Sender<ServerMessage>,
    connection: &Connection<'_>,
    state: &mut ConnectionState,
) -> Option<ServerMessage> {
    match serde_json::from_str::<ClientMessage>(text) {
        Ok(message) => {
            let Connection { registry, hosts, settings, relay_host } = connection;
            dispatch(message, tx, registry, hosts, settings, relay_host, state).await
        }
        Err(error) => match activity::refusal_for_undecodable(text) {
            Some((reason, request_id)) => {
                TALLY.activity(ActivityOutcome::refused(reason));
                Some(ServerMessage::ActivityRefused { reason, request_id })
            }
            None => {
                let reason = Refusal::for_unparseable(&error);
                TALLY.refused(reason);
                warn!(%error, reason = reason.as_str(), "unparseable signalling message; likely a client on a different version");
                Some(ServerMessage::error("protocol", "unrecognised message"))
            }
        },
    }
}
