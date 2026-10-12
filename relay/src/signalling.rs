//! Signalling: how a phone finds out where its Mac is, and how the two of them are handed a
//! session to meet in.
//!
//! Presence falls out of the connection rather than being tracked separately. A Mac is online
//! exactly while it holds a signalling WebSocket open, so there is no heartbeat to tune, no stale
//! registration to expire, and no way for the roster to disagree with reality — when the socket
//! closes, the host is gone, and the next phone that asks is told so.
//!
//! This is what replaces Bonjour across the internet. The TXT record's three fields — id, name and
//! protocol version — are the same three that travel here, because they are the same three facts:
//! who this Mac is, what it is called, and whether the two ends can speak to each other.

use std::collections::HashMap;
use std::net::IpAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// How many sessions one signalling connection may ask for. See `ConnectionState`.
const MAX_SESSIONS_PER_CONNECTION: usize = 64;

use crate::device_bindings::{Binding, DeviceBindings};
use crate::client_ip::{forwarded_address, is_loopback};
use crate::device_proof;
use crate::limits::PeerLimiter;

use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, Mutex, Semaphore};
use tokio::time;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::Message;
use tracing::{debug, info, warn};

use crate::apns::{ApnsClient, PushAction, PushRoute};
use crate::fcm::FcmClient;
use crate::push::{self, PushLimiter, PushTarget};

/// The only categories a Mac may name: the ones the phone registers for an agent approval, and for
/// the notice that a turn finished.
const AGENT_APPROVAL_CATEGORY_PREFIX: &str = "peering.agent.approval.";
const AGENT_FINISHED_CATEGORY: &str = "peering.agent.finished";

fn unix_now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs()
}

/// Hex characters. An APNs token is 64; an FCM token is about 160 characters before it is hex encoded behind a `fcm:` prefix.
const MAX_DEVICE_TOKEN_HEX: usize = 1024;

fn is_agent_category(category: &str) -> bool {
    category.starts_with(AGENT_APPROVAL_CATEGORY_PREFIX) || category == AGENT_FINISHED_CATEGORY
}
use crate::protocol::{hex, unhex, ClientMessage, ServerMessage};
use crate::quota::{Plan, QuotaTracker};
use crate::referrals::Standing;
use crate::session::{CLIENT_SLOT, HOST_SLOT, Registry, Token};
use crate::play_api::PlayVerifier;
use crate::playbilling::{self, PlayReceiptCache, PlayRejection};
use crate::redact::tag;
use crate::activity::{self, ActivityLimiter, ActivityPush, ActivityRefusal};
use crate::stats::{ActivityOutcome, Refusal, TALLY};
use crate::storekit::{Rejection, ReceiptCache, StoreKitVerifier, Trust};

/// How the relay describes itself to the two ends.
#[derive(Clone)]
pub struct Settings {
    /// The name clients should connect back to. `None` means "whatever address this client
    /// reached us on", which is right for a directly-addressed relay and needs no configuration
    /// for the loopback case.
    pub host: Option<String>,
    /// The control port **as clients reach it**, which need not be the port the relay binds. A host
    /// that forwards a port on a shared address picks both numbers, and only the outside one is
    /// reachable.
    pub public_control_port: u16,
    /// The video port as clients must reach it. One port for the whole relay, decided once at
    /// startup when the shared socket was bound, so the same number goes into every session's
    /// `ready` — which is the change that makes a host forwarding a handful of ports on a shared
    /// IPv4 workable at all. See `udp_relay`.
    pub video_port: u16,
    pub session_ttl: Duration,
    pub quota: Arc<QuotaTracker>,
    /// Decides whether a client's plan is Apple's or its own claim — see `storekit`.
    ///
    /// Beside the quota rather than inside it, because the two answer different questions: this one
    /// is what the client bought, and `quota` is what that buys them. Keeping the verification out
    /// of the counter is also what lets the counter be tested without a certificate in sight.
    pub receipts: Arc<StoreKitVerifier>,
    /// How many sessions may exist at once. See `Config::max_sessions`.
    pub max_sessions: usize,
    /// How many sockets may be open on the listener at once. See `Config::max_connections`.
    pub max_connections: usize,
    /// How long a socket has to finish becoming a WebSocket, and how long it may then sit silent.
    /// See `Config::handshake_timeout` and `Config::idle_timeout`.
    pub handshake_timeout: Duration,
    pub idle_timeout: Duration,
    /// APNs client, when the relay has been given a key. `None` means push notifications are
    /// not available; `NotifyDevice` messages from registered hosts are silently dropped.
    pub apns: Option<Arc<ApnsClient>>,
    /// FCM client, when the relay has been given a service account. `None` drops Android pushes.
    pub fcm: Option<Arc<FcmClient>>,
    /// Google Play purchase verification, when the relay has a service account and a package name.
    /// `None` leaves Play purchases unread, and a client's plan is decided as it was before Play.
    pub play: Option<Arc<PlayVerifier>>,
    /// Per peer address ceilings. See `limits`.
    pub limiter: Arc<PeerLimiter>,
    /// Whether `ConnectToHost` may only reach a host whose registration proved its device key.
    /// See `Config::require_proven_hosts`.
    pub require_proven_hosts: bool,
    /// Live Activity pushes per token across every connection. See `activity::SharedActivityBudget`.
    pub activity_budget: Arc<activity::SharedActivityBudget>,
}

/// The plan a connect is metered by, how it was arrived at, and why a purchase was refused.
struct Metering {
    plan: Plan,
    trust: Trust,
    refused: Option<&'static str>,
}

/// A Play purchase decides the plan when Play is configured and the client presents one. Otherwise
/// the Apple receipt decides, exactly as it did before Play existed.
async fn meter(
    settings: &Settings,
    state: &mut ConnectionState,
    claimed: Plan,
    jws: Option<&str>,
    play: Option<(&str, &str)>,
    client_key: Option<&str>,
) -> Metering {
    match (settings.play.as_deref(), play) {
        (Some(verifier), Some((token, product))) => {
            let verdict = verifier
                .verdict(&mut state.play_purchases, product, token, client_key, unix_now())
                .await;
            let resolved = playbilling::resolve(settings.receipts.trusts_claims(), claimed, Some(verdict));
            Metering {
                plan: resolved.plan,
                trust: resolved.trust,
                refused: resolved.rejected.map(PlayRejection::reason),
            }
        }
        _ => {
            let resolved = state.receipts.resolve(&settings.receipts, claimed, jws);
            Metering {
                plan: resolved.plan,
                trust: resolved.trust,
                refused: resolved.rejected.map(Rejection::reason),
            }
        }
    }
}

/// An action needs all three parts, and a category only the app registered: anything else is
/// dropped rather than forwarded under the phone's name.
fn push_action<'a>(
    category: Option<&'a str>,
    session_id: Option<&'a str>,
    approval_id: Option<&'a str>,
) -> Option<PushAction<'a>> {
    match (category, session_id, approval_id) {
        (Some(category), Some(session_id), Some(approval_id)) if is_agent_category(category) => {
            Some(PushAction { category, session_id, approval_id })
        }
        _ => None,
    }
}

/// What one signalling connection carries from message to message.
#[derive(Default)]
struct ConnectionState {
    /// The address this socket came from, or `None` where there is no per address accounting.
    peer: Option<IpAddr>,
    /// The device ID this socket registered as, so the registration can be removed when it closes.
    registered_as: Option<String>,
    /// How many sessions this one socket has asked for.
    ///
    /// **A ceiling on a socket as well as on the process.** The process-wide one bounds memory; this
    /// one stops a single connection from spending all of it and leaving every other client refused
    /// which turns the global ceiling into a denial of service of its own. Sixty-four is far past
    /// any honest use: a client allocates one session per connect, and a client reconnecting sixty
    /// times over one socket is a client in a loop.
    sessions_asked_for: usize,
    /// The verdict on the receipts this client has sent, so a JWS is verified once per session
    /// rather than once per message. See `storekit::ReceiptCache`.
    receipts: ReceiptCache,
    /// The Play verdicts this client has had, so Google is asked once per purchase per socket.
    play_purchases: PlayReceiptCache,
    /// Invite requests this socket has made. Each costs a signature check, and an honest client
    /// makes one or two.
    referral_requests: usize,
    /// Live Activity pushes this socket has sent, budgeted per activity token.
    activity_limiter: ActivityLimiter,
    /// `notifyDevice` pushes this socket has sent.
    push_limiter: PushLimiter,
}

/// Invite requests one socket may make before it is told to reconnect.
const MAX_REFERRAL_REQUESTS_PER_CONNECTION: usize = 16;

/// The identity an invite request proves, which is the device key, or the reply to refuse with.
///
/// Unlike metering, a missing or bad proof is a refusal here: an announced id would let one person
/// redeem once per install.
fn referral_identity(
    action: &str,
    client_id: &str,
    key: Option<&str>,
    signature: Option<&str>,
    stamp: Option<u64>,
) -> Result<String, ServerMessage> {
    let (Some(key), Some(signature), Some(stamp)) = (key, signature, stamp) else {
        return Err(ServerMessage::error(
            "proofRequired",
            "invites need a device key; update the app",
        ));
    };
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
    if !device_proof::time_is_current(stamp, now) {
        return Err(ServerMessage::error(
            "proofStale",
            "that request was signed for a time this relay will not accept",
        ));
    }
    let body = device_proof::referral_payload(action, client_id, stamp);
    if !device_proof::verifies(key, signature, body.as_bytes()) {
        return Err(ServerMessage::error(
            "proofInvalid",
            "that request does not prove it comes from the device it names",
        ));
    }
    Ok(key.to_string())
}

fn referral_reply(standing: Standing) -> ServerMessage {
    ServerMessage::Referral {
        code: standing.code,
        bonus_seconds: standing.bonus_seconds,
        bonus_ends_at: standing.bonus_ends_at,
        redeemed: standing.redeemed,
        invites_earned: standing.invites_earned,
        invites_max: standing.invites_max,
    }
}

/// The Macs that are currently registered, by device ID.
#[derive(Clone, Default)]
pub struct HostRegistry {
    inner: Arc<Mutex<HashMap<String, Host>>>,
    /// Who each device id belongs to.
    ///
    /// **Here rather than threaded through as its own parameter**, and the reason is that it is a
    /// property of this table rather than a second thing beside it: the rule it enforces is "only
    /// the device that registered this id may register it again", which is a statement about the
    /// entries below. It lives longer than any entry does, which is the whole point of it, and that
    /// is the one way in which it is not like the table it sits in.
    ///
    /// Behind an `Arc` because this whole type is `Clone` and every clone must be looking at the
    /// same bindings: a second copy that started empty would let a registration through on the
    /// connection that happened to hold the fresh one.
    bindings: Arc<DeviceBindings>,
}

struct Host {
    protocol_version: u16,
    /// Whether the registration proved the device key, as opposed to naming an id.
    proven: bool,
    /// The push channel for this Mac's signalling connection.
    tx: mpsc::Sender<ServerMessage>,
}

/// A host's registration, cloned out of the registry so the lock is not held while a session is
/// allocated underneath it.
struct HostRef {
    tx: mpsc::Sender<ServerMessage>,
    protocol_version: u16,
    proven: bool,
}

impl HostRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// The same registry, with device bindings that outlive the process.
    ///
    /// The failure is returned rather than logged here so that `main` can say at startup which of
    /// the two it got, the way it does for the usage log.
    pub fn with_bindings(path: Option<PathBuf>, max_bindings: usize) -> (Self, Option<std::io::Error>) {
        let (bindings, failure) = DeviceBindings::with_limit(path, max_bindings);
        (
            Self {
                bindings: Arc::new(bindings),
                ..Self::default()
            },
            failure,
        )
    }

    /// Registers a Mac, if it is entitled to the id it is claiming.
    ///
    /// **`proof` is the public key the registration proved control of, or `None` when it offered
    /// no proof at all.** The check is in `DeviceBindings`, and the shape of it is what lets this
    /// ship before every Mac in the field has updated: an id nobody has proved is registered by
    /// anyone, exactly as before, and an id somebody has proved is registered only by that device.
    async fn put(
        &self,
        device_id: &str,
        version: u16,
        tx: mpsc::Sender<ServerMessage>,
        proof: Option<&str>,
    ) -> Result<(), &'static str> {
        match self.bindings.check_and_bind(device_id, proof) {
            Binding::Refused(reason) => return Err(reason),
            // **Loud, because it is the one registration that cannot be judged here.** A device
            // that re-minted its identity and somebody who has taken an ID they do not own are the
            // same message with the same proof, and only a person reading this can tell them apart.
            // The registration goes through either way: refusing it is what used to let a stranger
            // take a Mac off the relay for good by arriving first.
            Binding::Rebound => {
                warn!(
                    device_id = %tag(device_id),
                    "this device id was bound to a different key and is now bound to this one"
                );
            }
            Binding::Bound | Binding::Matched => {}
        }

        self.inner.lock().await.insert(
            device_id.to_string(),
            Host {
                protocol_version: version,
                proven: proof.is_some(),
                tx,
            },
        );
        Ok(())
    }

    /// Removes a registration **only if this connection still owns it**.
    ///
    /// Without the ownership check, a Mac that reconnects — a laptop changing networks does this
    /// routinely — has its old socket close *after* the new one registered, and the cleanup for
    /// the old one would delete the new one's entry. The Mac would then be unreachable while
    /// believing it was online, which is the worst of both.
    async fn remove_if_ours(&self, device_id: &str, tx: &mpsc::Sender<ServerMessage>) {
        let mut inner = self.inner.lock().await;
        if inner
            .get(device_id)
            .is_some_and(|host| host.tx.same_channel(tx))
        {
            inner.remove(device_id);
        }
    }

    /// A host whose connection has gone is not present even if its cleanup never ran, which is
    /// what a panic in the connection task leaves behind.
    async fn entry_for(&self, device_id: &str) -> Option<HostRef> {
        let mut inner = self.inner.lock().await;
        if inner.get(device_id).is_some_and(|host| host.tx.is_closed()) {
            inner.remove(device_id);
            return None;
        }
        inner.get(device_id).map(|host| HostRef {
            tx: host.tx.clone(),
            protocol_version: host.protocol_version,
            proven: host.proven,
        })
    }

    pub async fn online_count(&self) -> usize {
        self.inner.lock().await.values().filter(|host| !host.tx.is_closed()).count()
    }

    /// Waits for pending device bindings to reach the disk, for a clean shutdown.
    pub fn flush_bindings(&self) {
        self.bindings.flush();
    }
}

/// Accepts signalling connections. `tls` wraps each socket before the WebSocket handshake; without
/// it the signalling channel is plaintext, which is only appropriate on loopback.
pub async fn serve(
    listener: TcpListener,
    registry: Arc<Registry>,
    hosts: HostRegistry,
    settings: Settings,
    tls: Option<tokio_rustls::TlsAcceptor>,
) {
    info!(
        addr = %listener.local_addr().map(|a| a.to_string()).unwrap_or_default(),
        max_connections = settings.max_connections,
        handshake_seconds = settings.handshake_timeout.as_secs(),
        idle_seconds = settings.idle_timeout.as_secs(),
        "signalling listening"
    );

    // **Two bounds on a socket that has not earned its keep yet.** Nothing in front of this listener
    // authenticates anybody: an accepted socket is a task and a file descriptor handed to whoever
    // asked, and before these existed a peer could take as many as it liked and hold each one for
    // ever by saying nothing at all. The permits are the count and the timeouts are the duration,
    // and both are needed: a count alone lets the same number of sockets be held indefinitely, and
    // a duration alone has no ceiling to fail against under a flood.
    //
    // A connection that arrives with every permit taken is closed rather than queued. Queuing would
    // turn a flood into a backlog of work for a relay that is already at its limit, and the clients
    // that matter here retry: the Mac's registration reconnects on a backoff, and the app's
    // signalling connections are opened per request.
    // Clamped, because `Semaphore::new` panics above its own maximum and a panic at startup is a
    // relay that will not run: an operator who writes an enormous number asking for no limit gets
    // the largest number tokio will take instead of a process that dies explaining nothing.
    let permits = Arc::new(Semaphore::new(
        settings.max_connections.min(Semaphore::MAX_PERMITS),
    ));

    loop {
        let (stream, peer_address) = match listener.accept().await {
            Ok(pair) => pair,
            Err(error) => {
                warn!(%error, "signalling listener could not accept");
                tokio::time::sleep(Duration::from_millis(50)).await;
                continue;
            }
        };

        let Ok(permit) = Arc::clone(&permits).try_acquire_owned() else {
            warn!("refused a signalling connection: the listener is at its limit");
            drop(stream);
            continue;
        };

        let peer = Some(peer_address.ip());
        let Some(ip_permit) = admit_peer(&settings.limiter, peer) else {
            TALLY.refused(Refusal::PerIpLimit);
            debug!("refused a signalling connection: this address is at its limit");
            drop(stream);
            continue;
        };

        // The address this client reached us on is the one it can reach us on again, which is why
        // this is read from the accepted socket rather than from configuration.
        let relay_host = match (&settings.host, stream.local_addr()) {
            (Some(configured), _) => configured.clone(),
            (None, Ok(local)) => local.ip().to_string(),
            (None, Err(_)) => "127.0.0.1".to_string(),
        };

        let registry = Arc::clone(&registry);
        let hosts = hosts.clone();
        let settings = settings.clone();

        match &tls {
            Some(acceptor) => {
                let acceptor = acceptor.clone();
                tokio::spawn(async move {
                    // The handshake is bounded like everything else here: a socket that opens a TLS
                    // connection and never finishes it would otherwise hold its permit for ever.
                    let secured = time::timeout(settings.handshake_timeout, acceptor.accept(stream))
                        .await;
                    // Each arm that only logs is braced, which is not decoration: a tracing macro
                    // leaves a temporary alive to the end of the enclosing match, and this match
                    // contains an `.await` in another arm, so the whole future stops being `Send`
                    // and `tokio::spawn` refuses it.
                    match secured {
                        Ok(Ok(secured)) => {
                            handle(secured, peer, relay_host, registry, hosts, settings).await;
                        }
                        Ok(Err(error)) => {
                            debug!(%error, "signalling TLS handshake failed");
                        }
                        Err(_) => {
                            debug!("signalling TLS handshake timed out");
                        }
                    }
                    // Dropped with the permits, which is what returns them to their pools.
                    drop((permit, ip_permit));
                });
            }
            None => {
                tokio::spawn(async move {
                    handle(stream, peer, relay_host, registry, hosts, settings).await;
                    drop((permit, ip_permit));
                });
            }
        }
    }
}

/// `Ok(None)` is an address with no accounting, which is every address when `peer` is unknown.
fn admit_peer(
    limiter: &Arc<PeerLimiter>,
    peer: Option<IpAddr>,
) -> Option<Option<crate::limits::Permit>> {
    match peer {
        Some(ip) => limiter.admit_signalling(ip).map(Some),
        None => Some(None),
    }
}

#[allow(clippy::result_large_err)] // the handshake callback's error type is tungstenite's
async fn handle<S>(
    stream: S,
    peer: Option<IpAddr>,
    relay_host: String,
    registry: Arc<Registry>,
    hosts: HostRegistry,
    settings: Settings,
) where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    // 64 KB is large enough for the biggest valid message — a `ConnectToHost` carrying a receipt,
    // which is a few kilobytes of base64 and is capped at `storekit::MAX_JWS_BYTES` — by a generous
    // margin, and small enough to close a connection sending garbage before it allocates a
    // meaningful amount of memory.
    let mut config = WebSocketConfig::default();
    config.max_message_size = Some(64 * 1024);
    config.max_frame_size = Some(64 * 1024);
    // Bounded, for the same reason the TLS handshake above is: this is a second place a peer can
    // arrive and then say nothing, and without a deadline the connection it holds is held for ever.
    let forwarded: Arc<std::sync::Mutex<Option<IpAddr>>> = Arc::default();
    let record = Arc::clone(&forwarded);
    let header = settings.limiter.client_header();
    let limiter = Arc::clone(&settings.limiter);
    let ws = match time::timeout(
        settings.handshake_timeout,
        tokio_tungstenite::accept_hdr_async_with_config(
            stream,
            move |request: &tokio_tungstenite::tungstenite::handshake::server::Request,
                  response: tokio_tungstenite::tungstenite::handshake::server::Response| {
                let named = peer.and_then(|peer| forwarded_address(peer, request.headers(), header));
                if let Some(ip) = named {
                    *record.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(ip);
                } else if peer.is_some_and(is_loopback) && limiter.first_headerless_loopback() {
                    warn!(header = ?header, "a loopback connection carried no usable client address header; per-address limits do nothing until the proxy sets it");
                }
                Ok(response)
            },
            Some(config),
        ),
    )
    .await
    {
        Ok(Ok(ws)) => ws,
        Ok(Err(error)) => {
            debug!(%error, "websocket handshake failed");
            return;
        }
        Err(_) => {
            debug!("websocket handshake timed out");
            return;
        }
    };

    let (mut sink, mut source) = ws.split();

    // Every outgoing message goes through here, including replies to the message being handled.
    // That is what lets the select below own `sink` exclusively: a reply written straight to the
    // sink from the read arm would need it borrowed in both arms at once.
    let (tx, mut rx) = mpsc::channel::<ServerMessage>(32);
    // Behind a local reverse proxy the socket peer is loopback and the client's address is in the
    // headers; its limits are taken here, once the upgrade has said who it is.
    let forwarded = forwarded.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
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
    let mut state = ConnectionState { peer: forwarded.or(peer), ..ConnectionState::default() };
    // One write is given as long as the handshake was: a peer that stops reading must not hold a
    // task, and the idle deadline below is not polled while a write is pending.
    let write_timeout = settings.handshake_timeout;

    // **The idle deadline, and why it is not the same as the handshake one.** A registered Mac
    // holds this connection open for as long as it is running, and an app's signalling connections
    // are opened per request, so "silent" is the normal state of the one that matters. What makes
    // this safe is that the Mac says something anyway: it pings every 25 seconds, so a deadline
    // three times that is a connection that has genuinely gone, not one that is merely quiet.
    //
    // Every frame resets it, in either direction: a peer that is reading replies while sending
    // nothing is a peer that is still there.
    let mut deadline = Box::pin(time::sleep(settings.idle_timeout));
    let idle = settings.idle_timeout;

    loop {
        // Biased, with the deadline first and the writer before the reader, so that neither the
        // clock nor the queue of replies can be starved by a peer that keeps the reader ready.
        tokio::select! {
            biased;
            _ = &mut deadline => {
                debug!("signalling connection has been idle for too long");
                break;
            }
            outgoing = rx.recv() => {
                deadline.as_mut().reset(time::Instant::now() + idle);
                let Some(message) = outgoing else { break };
                let Ok(json) = serde_json::to_string(&message) else { continue };
                match time::timeout(write_timeout, sink.send(Message::Text(json.into()))).await {
                    Ok(Ok(())) => {}
                    Ok(Err(_)) => break,
                    Err(_) => {
                        debug!("signalling peer stopped reading; dropping it");
                        break;
                    }
                }
            }
            incoming = source.next() => {
                deadline.as_mut().reset(time::Instant::now() + idle);
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        let reply = match serde_json::from_str::<ClientMessage>(&text) {
                            Ok(message) => {
                                dispatch(message, &tx, &registry, &hosts, &settings, &relay_host, &mut state).await
                            }
                            Err(error) => match activity::refusal_for_undecodable(&text) {
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
                        };
                        if let Some(message) = reply {
                            // Never awaited: this loop is the only reader of the queue, so waiting
                            // on a full one would wait on itself. Thirty-two unsent replies mean a
                            // client that is not reading.
                            if tx.try_send(message).is_err() {
                                debug!("signalling reply queue is full; dropping the peer");
                                break;
                            }
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => break,
                    // Ping, Pong and Binary are not part of this conversation. tungstenite answers
                    // protocol-level pings itself, so there is nothing to do for them here.
                    Some(Ok(_)) => {}
                    Some(Err(error)) => {
                        debug!(%error, "signalling read failed");
                        break;
                    }
                }
            }
        }
    }

    if let Some(device_id) = state.registered_as {
        hosts.remove_if_ours(&device_id, &tx).await;
        info!(device_id = %tag(&device_id), "host went offline");
    }
}

/// Validates and sends one Live Activity push for a registered host. The APNs call runs in the
/// background; a failure there reaches the host as `activityRefused` on the same socket.
fn notify_activity(
    push: ActivityPush,
    self_tx: &mpsc::Sender<ServerMessage>,
    settings: &Settings,
    state: &mut ConnectionState,
) -> Option<ServerMessage> {
    let request_id = push.request_id.clone().filter(|id| id.chars().count() <= activity::MAX_REQUEST_ID_CHARS);
    let refuse = |refusal: ActivityRefusal| {
        TALLY.activity(ActivityOutcome::refused(refusal));
        Some(ServerMessage::ActivityRefused { reason: refusal, request_id: request_id.clone() })
    };
    let request = match activity::build(&push, unix_now()) {
        Ok(request) => request,
        Err(refusal) => return refuse(refusal),
    };
    if !matches!(push::target_for(&push.activity_token), PushTarget::Apns(_)) {
        return refuse(ActivityRefusal::InvalidToken);
    }
    let now = Instant::now();
    if !state.activity_limiter.allow(&push.activity_token, now) || !settings.activity_budget.allow(&push.activity_token, now) {
        TALLY.activity(ActivityOutcome::DroppedRate);
        return None;
    }
    let Some(apns) = settings.apns.as_ref().map(Arc::clone) else {
        return refuse(ActivityRefusal::Unavailable);
    };
    let reply = self_tx.clone();
    tokio::spawn(async move {
        match apns.send_activity(&push.activity_token, push.environment, &request).await {
            Ok(()) => TALLY.activity(ActivityOutcome::Sent),
            Err(failure) => {
                let refusal = failure.refusal();
                TALLY.activity(ActivityOutcome::refused(refusal));
                let _ = reply.try_send(ServerMessage::ActivityRefused { reason: refusal, request_id });
            }
        }
    });
    None
}

/// Handles one client message, returning the reply to send back to *this* connection.
async fn dispatch(
    message: ClientMessage,
    self_tx: &mpsc::Sender<ServerMessage>,
    registry: &Arc<Registry>,
    hosts: &HostRegistry,
    settings: &Settings,
    relay_host: &str,
    state: &mut ConnectionState,
) -> Option<ServerMessage> {
    // IDs and names are short strings — device IDs are UUIDs (36 chars) and names are
    // human-readable labels. Cap at 256 bytes so a misbehaving client cannot accumulate
    // unboundedly large strings in the host registry or in log lines.
    const MAX_FIELD: usize = 256;

    match message {
        ClientMessage::RegisterHost {
            device_id,
            name,
            protocol_version,
            public_key,
            proof,
            proof_time,
        } => {
            if device_id.len() > MAX_FIELD || name.len() > MAX_FIELD {
                return Some(ServerMessage::error("invalid", "field too long"));
            }

            // **The proof, when there is one, is checked before anything is written.** Three
            // fields or none: a registration carrying one of them is not a partial proof to be
            // salvaged, it is a message this relay does not understand, and guessing at it is how
            // a check becomes a hole.
            let proved: Option<String> = match (&public_key, &proof, proof_time) {
                (Some(key), Some(signature), Some(stamp)) => {
                    let now = SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_secs();
                    if !device_proof::time_is_current(stamp, now) {
                        TALLY.refused(Refusal::BadProof);
                        warn!(device_id = %tag(&device_id), "a device registration was signed for a different time");
                        return Some(ServerMessage::error(
                            "proofStale",
                            "that registration was signed for a time this relay will not accept",
                        ));
                    }
                    let body = device_proof::payload(&device_id, stamp);
                    if !device_proof::verifies(key, signature, body.as_bytes()) {
                        TALLY.refused(Refusal::BadProof);
                        warn!(device_id = %tag(&device_id), "a device registration did not prove the key it claimed");
                        return Some(ServerMessage::error(
                            "proofInvalid",
                            "that registration does not prove it comes from the device it names",
                        ));
                    }
                    Some(key.clone())
                }
                _ => None,
            };

            if let Err(reason) = hosts
                .put(
                    &device_id,
                    protocol_version,
                    self_tx.clone(),
                    proved.as_deref(),
                )
                .await
            {
                // Loud, and at warn rather than debug: this is either a device that has lost its
                // key, or somebody claiming an id they do not own, and both are worth seeing in
                // the journal without turning a log level up to find them.
                TALLY.refused(Refusal::BadProof);
                warn!(device_id = %tag(&device_id), reason, "refused a device registration");
                return Some(ServerMessage::error("deviceRefused", reason));
            }

            // One live registration per connection: a second replaces the first, so the earlier
            // id does not linger in the table reporting a Mac online that this socket no longer
            // stands for.
            if let Some(previous) = state.registered_as.replace(device_id.clone())
                && previous != device_id
            {
                hosts.remove_if_ours(&previous, self_tx).await;
            }
            info!(
                device_id = %tag(&device_id),
                protocol_version,
                proved = proved.is_some(),
                "host registered"
            );
            Some(ServerMessage::Registered {
                session_ttl_seconds: settings.session_ttl.as_secs(),
            })
        }

        ClientMessage::ConnectToHost {
            host_id,
            client_id,
            protocol_version,
            api_key,
            plan,
            jws_representation,
            public_key,
            proof,
            proof_time,
            play_purchase_token,
            play_product_id,
        } => {
            if host_id.len() > MAX_FIELD || client_id.len() > MAX_FIELD {
                return Some(ServerMessage::error("invalid", "field too long"));
            }
            if let Some(api_key) = &api_key {
                if api_key.len() > MAX_FIELD {
                    return Some(ServerMessage::error("invalid", "field too long"));
                }
            }

            // **What the allowance hangs from.** The stated id when there is no proof, which is
            // every build before this one and the fallback here; the key when there is one, which
            // is what makes a reinstall cost the same as staying installed. Read the client
            // payload rather than the host's: the two are signed with the same key and carry the
            // same field names, so the version tag inside the signed string is the only thing
            // keeping one from being presented as the other.
            //
            // A proof that does not verify is *not* a refusal, and that is deliberate: this is
            // metering, and refusing to connect over it would turn a clock skew into an outage for
            // somebody who has done nothing wrong. The client is metered by its stated id instead,
            // which is exactly where it would have been without the fields at all. The line says
            // which happened, because "why is this device's usage not where I expect it" is a
            // question an operator asks.
            let proved: Option<String> = match (&public_key, &proof, proof_time) {
                (Some(key), Some(signature), Some(stamp)) => {
                    let now = SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_secs();
                    if device_proof::time_is_current(stamp, now) {
                        let body = device_proof::client_payload(&client_id, stamp);
                        if device_proof::verifies(key, signature, body.as_bytes()) {
                            Some(key.clone())
                        } else {
                            info!(client_id = %tag(&client_id), "a client proof did not verify; metered by id");
                            None
                        }
                    } else {
                        info!(client_id = %tag(&client_id), "a client proof was signed for a different time; metered by id");
                        None
                    }
                }
                (None, None, None) => None,
                // Two fields of three. Not salvaged, and not worth a refusal: the client is
                // metered by its id, which is what a build that sends none of them gets.
                _ => {
                    info!(client_id = %tag(&client_id), "a client proof was incomplete; metered by id");
                    None
                }
            };
            let metered_as = proved.as_deref().unwrap_or(&client_id);

            // The plan is resolved before anything is allocated, and the raw strings are dropped
            // here: what travels on is the resolved plan and how it was arrived at, so nothing
            // downstream can be tempted to read a name this relay does not know, or to treat a
            // receipt as proof without having verified it. The receipt is verified at most once per
            // connection, which is what `ReceiptCache` is for, and it is never logged.
            let claimed = Plan::from_wire(plan.as_deref());
            let play = match (play_purchase_token.as_deref(), play_product_id.as_deref()) {
                (Some(token), Some(product)) => Some((token, product)),
                _ => None,
            };
            let Metering { plan, trust, refused } = meter(
                settings,
                state,
                claimed,
                jws_representation.as_deref(),
                play,
                proved.as_deref(),
            )
            .await;

            // One line, and only when a receipt was sent and refused: it is the answer to "why is
            // this client metered as free", which is the question an operator asks when a paying
            // client reports being cut off. The reason is the part that answers it, and one of
            // them is worth knowing by sight before reading the rest: `not_a_real_purchase` is a
            // TestFlight build's sandbox receipt, which this relay refuses by name whatever the
            // switch says, because Apple gives those away for nothing.
            if let Some(reason) = refused {
                info!(
                    client_id = %tag(&client_id),
                    plan = plan.as_str(),
                    plan_trust = trust.as_str(),
                    reason,
                    "receipt refused"
                );
            }

            // Check relay quota before allocating a session. Paid keys bypass the counter; a plan
            // with an allowance is blocked when its allowance for this window is exhausted, and
            // the two unlimited plans are not blocked at all.
            //
            // **This is not the whole of the enforcement**, and it cannot be: it answers the
            // question once, for the instant the session is handed out, and what it hands out is a
            // connection that can then stay open for days. `tcp_relay` charges the same counter
            // while the splice runs and ends the session when the allowance is gone, which is what
            // makes the number here a starting point rather than a promise. Both questions are
            // asked of the same function, so they cannot disagree about what a plan is allowed.
            let remaining = settings.quota.remaining(metered_as, api_key.as_deref(), plan);
            if remaining == Some(0) {
                // Logged because it is the line an operator is asked about: "why was I cut off"
                // is answered here, with the plan that was applied, whether Apple or the client
                // said so, and so whether the client was metered as free when it did not think
                // it was.
                TALLY.refused(Refusal::QuotaRefusedAtConnect);
                info!(
                    client_id = %tag(&client_id),
                    plan = plan.as_str(),
                    plan_trust = trust.as_str(),
                    "relay allowance exhausted"
                );
                return Some(ServerMessage::error(
                    "quotaExceeded",
                    "relay allowance exhausted for this period",
                ));
            }

            let Some(host) = hosts.entry_for(&host_id).await else {
                TALLY.refused(Refusal::HostNotRegistered);
                info!(host_id = %tag(&host_id), "asked for a host that is not registered");
                return Some(ServerMessage::HostOffline { device_id: host_id });
            };

            // A host that only named its id cannot be told from one invented to soak up sessions,
            // so where the operator has asked for it, only a host that proved its key is a target.
            if settings.require_proven_hosts && !host.proven {
                TALLY.refused(Refusal::HostNotRegistered);
                info!(host_id = %tag(&host_id), "asked for a host that has not proved its key");
                return Some(ServerMessage::HostOffline { device_id: host_id });
            }

            // Checked here so a mismatched pair is told before either end spends a round trip on a
            // handshake that would fail anyway. The two ends check it again themselves — this is a
            // courtesy, not the enforcement.
            if host.protocol_version != protocol_version {
                TALLY.refused(Refusal::VersionMismatch);
                return Some(ServerMessage::error(
                    "version",
                    format!(
                        "host speaks v{}, client speaks v{protocol_version}",
                        host.protocol_version
                    ),
                ));
            }

            // No video socket is bound here any more, and that is the point of the shared one: this
            // is where a session used to be refused because the whole video range was in use, and
            // now the only thing allocation can run out of is memory. `allocate` opens the session's
            // routes in the shared table before it returns.
            //
            // The account goes in with it. It is the same plan and key the check above used, in a
            // shape that can travel: the splice that will be charged for this session starts in
            // another module with nothing but a control token, so whose allowance to spend and
            // which plan's number bounds it has to be part of what a session is.
            // **The two ceilings, before anything is minted.** The per-socket one is checked first
            // because it is the cheaper answer, and because a socket that has asked sixty-four
            // times is not a client that should be told "try again shortly", it should be told to
            // stop, which is what this refusal says.
            if state.sessions_asked_for >= MAX_SESSIONS_PER_CONNECTION {
                warn!(client_id = %tag(&client_id), "refused: one connection has asked for too many sessions");
                return Some(ServerMessage::error(
                    "tooManySessions",
                    "this connection has asked for too many sessions; reconnect to try again",
                ));
            }

            let unspliced = match state.peer {
                Some(ip) => {
                    if !settings.limiter.allow_allocation(ip) {
                        TALLY.refused(Refusal::PerIpLimit);
                        warn!(client_id = %tag(&client_id), "refused: this address is allocating sessions too fast");
                        return Some(ServerMessage::error(
                            "tooManySessions",
                            "too many sessions from this address; try again in a minute",
                        ));
                    }
                    let Some(permit) = settings.limiter.admit_unspliced(ip) else {
                        TALLY.refused(Refusal::PerIpLimit);
                        warn!(client_id = %tag(&client_id), "refused: this address has too many sessions nobody has joined");
                        return Some(ServerMessage::error(
                            "tooManySessions",
                            "too many unfinished sessions from this address; try again shortly",
                        ));
                    };
                    Some(permit)
                }
                None => None,
            };
            state.sessions_asked_for += 1;

            let account = settings.quota.account(metered_as, api_key.as_deref(), plan);

            // `None` is the relay at its ceiling. Said plainly rather than dressed up: a client
            // that is told the relay is full can wait and try again, and one that is told nothing
            // waits for a session that was never going to arrive.
            let Some(allocated) = registry.allocate_guarded(&host_id, &client_id, account, unspliced).await else {
                // Read into a local first. An `.await` inside a tracing macro's field list leaves
                // the macro's arguments alive across the await point, and the future stops being
                // `Send`, which `tokio::spawn` refuses two call frames up with an error that names
                // neither this line nor this cause.
                let sessions = registry.len().await;
                warn!(client_id = %tag(&client_id), sessions, "refused: the relay is at its session ceiling");
                return Some(ServerMessage::error(
                    "relayFull",
                    "the relay is at capacity; try again in a minute",
                ));
            };

            // The name is here because it is the one thing that makes this log line useful to
            // whoever is running the relay: a device ID identifies a machine to a database, and a
            // name identifies it to a person reading `journalctl`. The plan is here because it is
            // what decides whether this session is metered at all, and an operator reading a
            // session back needs that settled by the line rather than inferred from the client —
            // which is what `plan_trust` is for: `verified` means Apple signed the plan, `claimed`
            // means the client's word for it, `neither` means the free allowance.
            TALLY.session_allocated();
            info!(
                host_id = %tag(&host_id),
                client_id = %tag(&client_id),
                // Which of the two the time is charged to, and it is a field rather than a second
                // id in the line because the two are usually the same string: an operator asking
                // "why is this client's usage not where I expect it" needs to see that it is not.
                metered_by = if proved.is_some() { "key" } else { "id" },
                video_port = settings.video_port,
                plan = plan.as_str(),
                plan_trust = trust.as_str(),
                "session allocated"
            );

            // The two ends get *different* video tokens, which is the one place the messages they
            // receive diverge: their tokens are what the shared video socket routes on, so a shared
            // one could not say which end a datagram came from. See `VideoRoutes`. The control token
            // is shared because it is presented once by each side and used up.
            let ready = |video_token: Token| ServerMessage::SessionReady {
                control_host: relay_host.to_string(),
                control_port: settings.public_control_port,
                video_host: relay_host.to_string(),
                // The same number for every session, because every session sends to the same port.
                video_port: settings.video_port,
                control_token: hex(&allocated.control_token),
                video_token: hex(&video_token),
                remaining_seconds: remaining,
            };

            // Pushed to the Mac first. It did not ask for this, so a failure here means the Mac has
            // gone away between registering and now — reported to the phone rather than leaving it
            // waiting on a session the other end will never join.
            let delivered = time::timeout(
                settings.handshake_timeout,
                host.tx.send(ready(allocated.video_tokens[HOST_SLOT])),
            )
            .await;
            if !matches!(delivered, Ok(Ok(()))) {
                TALLY.refused(Refusal::HostOffline);
                warn!(host_id = %tag(&host_id), "host went away while its session was being set up");
                registry.release(&allocated.control_token).await;
                return Some(ServerMessage::HostOffline { device_id: host_id });
            }

            Some(ready(allocated.video_tokens[CLIENT_SLOT]))
        }

        // One end asking where the other is, so the two can try a path between themselves.
        //
        // A pure read of a table the datagram path already fills, and deliberately not a wait: the
        // answer is whatever the routing table knows at this instant, and "the peer has not spoken
        // yet" is reported rather than parked on. Waiting would hold a task per session on a
        // connection that may never need one, and the asker is about to send its own bind datagram
        // — the address it wants is a few milliseconds behind the question, not a reason to keep
        // the relay holding it.
        //
        // Nothing here decides whether the answer is *useful*. Whether the peer's NAT will accept a
        // packet from a third party is not something this process can know, and the two ends settle
        // it themselves by trying. This hands over an observation and no promise.
        ClientMessage::RequestPeerAddress { video_token } => {
            let Some(token) = unhex(&video_token) else {
                return Some(ServerMessage::error(
                    "invalid",
                    "video token is not 16 bytes of hex",
                ));
            };

            match registry.routes().peer_address(&token) {
                Some(address) => Some(ServerMessage::PeerAddress {
                    host: address.ip().to_string(),
                    port: address.port(),
                }),
                None => Some(ServerMessage::error(
                    "peerAddressUnknown",
                    "the other end of this session has not sent a datagram yet",
                )),
            }
        }

        // The same lookup `ConnectToHost` does a few lines above, asked as a question rather than
        // as the first half of opening a session. Deliberately without the version check that one
        // does: a phone asking whether its Mac is up has not committed to a session yet, and a Mac
        // that is present but speaks an older protocol is present.
        //
        // No rate limit, and the reason is that there is nothing here to limit: an answer is a
        // hashmap lookup on a key the client has to already know, device ids are UUIDs, and a
        // client that wanted to enumerate them would have to guess 128 bits per ask.
        ClientMessage::HostPresence { host_id } => {
            let online = hosts.entry_for(&host_id).await.is_some();
            Some(ServerMessage::HostPresence { host_id, online })
        }

        ClientMessage::NotifyDevice {
            device_token,
            title,
            body,
            source,
            category,
            session_id,
            approval_id,
        } => {
            // Only registered Macs may ask for pushes. An unregistered connection asking for one
            // has no client to push to and no session to trace it back to.
            let Some(host_id) = state.registered_as.clone() else {
                return Some(ServerMessage::error(
                    "unauthorized",
                    "only registered hosts may request push notifications",
                ));
            };
            // Refuse absurdly large fields before they reach the APNs payload builder.
            if device_token.len() > MAX_DEVICE_TOKEN_HEX
                || title.len() > 256
                || body.len() > 512
                || source.as_ref().is_some_and(|s| s.len() > 128)
                || category.as_ref().is_some_and(|s| s.len() > 128)
                || session_id.as_ref().is_some_and(|s| s.len() > 128)
                || approval_id.as_ref().is_some_and(|s| s.len() > 256)
            {
                return Some(ServerMessage::error("invalid", "field too long"));
            }
            if !state.push_limiter.allow(Instant::now()) {
                warn!(host = %tag(&host_id), "notifyDevice over its budget, dropped");
                return None;
            }
            // The Mac's ID is the relay's own record of who asked, not something the Mac says about
            // itself, so a tap can only ever open the Mac that sent it. A token's kind decides which
            // service carries it; a service that is not configured drops the push, as it always has.
            match push::target_for(&device_token) {
                PushTarget::Fcm(token) => {
                    if let Some(fcm) = settings.fcm.as_ref().map(Arc::clone) {
                        tokio::spawn(async move {
                            let action = push_action(category.as_deref(), session_id.as_deref(), approval_id.as_deref());
                            let route = PushRoute { host_id: &host_id, source: source.as_deref(), action };
                            if let Err(e) = fcm.send(&token, &title, &body, Some(route)).await {
                                warn!(error = %e, "FCM notification failed");
                            }
                        });
                    }
                }
                PushTarget::Apns(_) => {
                    if let Some(apns) = settings.apns.as_ref().map(Arc::clone) {
                        tokio::spawn(async move {
                            let action = push_action(category.as_deref(), session_id.as_deref(), approval_id.as_deref());
                            let route = PushRoute { host_id: &host_id, source: source.as_deref(), action };
                            if let Err(e) = apns.send(&device_token, &title, &body, Some(route)).await {
                                warn!(error = %e, "APNs notification failed");
                            }
                        });
                    }
                }
            }
            None
        }

        ClientMessage::NotifyActivity(push) => {
            if state.registered_as.is_none() {
                return Some(ServerMessage::error(
                    "unauthorized",
                    "only registered hosts may request push notifications",
                ));
            }
            notify_activity(push, self_tx, settings, state)
        }

        ClientMessage::ReferralStatus { client_id, public_key, proof, proof_time } => {
            if client_id.len() > MAX_FIELD {
                return Some(ServerMessage::error("invalid", "field too long"));
            }
            if state.referral_requests >= MAX_REFERRAL_REQUESTS_PER_CONNECTION {
                return Some(ServerMessage::error(
                    "tooManyRequests",
                    "this connection has made too many invite requests; reconnect to try again",
                ));
            }
            state.referral_requests += 1;
            let identity = match referral_identity(
                "status",
                &client_id,
                public_key.as_deref(),
                proof.as_deref(),
                proof_time,
            ) {
                Ok(identity) => identity,
                Err(refusal) => return Some(refusal),
            };
            Some(match settings.quota.referrals().standing(&identity, unix_now()) {
                Ok(standing) => referral_reply(standing),
                Err(refusal) => ServerMessage::error(refusal.code(), refusal.message()),
            })
        }

        ClientMessage::RedeemReferral { client_id, code, public_key, proof, proof_time } => {
            if client_id.len() > MAX_FIELD || code.len() > MAX_FIELD {
                return Some(ServerMessage::error("invalid", "field too long"));
            }
            if state.referral_requests >= MAX_REFERRAL_REQUESTS_PER_CONNECTION {
                return Some(ServerMessage::error(
                    "tooManyRequests",
                    "this connection has made too many invite requests; reconnect to try again",
                ));
            }
            state.referral_requests += 1;
            let identity = match referral_identity(
                &format!("redeem:{code}"),
                &client_id,
                public_key.as_deref(),
                proof.as_deref(),
                proof_time,
            ) {
                Ok(identity) => identity,
                Err(refusal) => return Some(refusal),
            };
            Some(match settings.quota.referrals().redeem_from(&identity, &code, unix_now(), state.peer) {
                Ok(standing) => {
                    info!(client_id = %tag(&client_id), "an invite code was redeemed");
                    referral_reply(standing)
                }
                Err(refusal) => {
                    info!(client_id = %tag(&client_id), reason = refusal.code(), "an invite code was refused");
                    ServerMessage::error(refusal.code(), refusal.message())
                }
            })
        }

        ClientMessage::Ping => Some(ServerMessage::Pong),
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_device_token_limit_leaves_room_for_an_fcm_token() {
        let fcm_hex_len = ("fcm:".len() + 170) * 2;
        assert!(fcm_hex_len <= super::MAX_DEVICE_TOKEN_HEX);
        assert!(64 <= super::MAX_DEVICE_TOKEN_HEX, "an APNs token still fits");
    }

    use super::*;
    use crate::client_ip::ClientIpHeader;
    use crate::config::PlanAllowances;
    use crate::referrals::{ReferralTerms, Referrals};

    #[test]
    fn a_mac_may_name_only_the_categories_the_phone_registers() {
        assert!(is_agent_category("peering.agent.approval.tool"));
        assert!(is_agent_category("peering.agent.approval.options.abc"));
        assert!(is_agent_category("peering.agent.finished"));
        assert!(!is_agent_category("peering.agent.finished.extra"));
        assert!(!is_agent_category("com.apple.something"));
    }

    fn channel() -> (mpsc::Sender<ServerMessage>, mpsc::Receiver<ServerMessage>) {
        mpsc::channel(4)
    }

    use p256::ecdsa::{Signature, SigningKey, signature::Signer};

    fn device_key(seed: u8) -> (SigningKey, String) {
        let signing = SigningKey::from_bytes(&[seed; 32].into()).expect("a valid scalar");
        let public = crate::protocol::bytes_hex(&signing.verifying_key().to_sec1_bytes());
        (signing, public)
    }

    fn signed(signing: &SigningKey, action: &str, client_id: &str, stamp: u64) -> String {
        let body = device_proof::referral_payload(action, client_id, stamp);
        let signature: Signature = signing.sign(body.as_bytes());
        crate::protocol::bytes_hex(signature.to_der().as_bytes())
    }

    async fn ask(settings: &Settings, message: ClientMessage) -> Option<ServerMessage> {
        let (tx, _rx) = channel();
        let registry = Arc::new(Registry::new(usize::MAX));
        let mut state = ConnectionState::default();
        dispatch(message, &tx, &registry, &HostRegistry::new(), settings, "127.0.0.1", &mut state).await
    }

    fn status_request(seed: u8, client_id: &str) -> ClientMessage {
        let (signing, public) = device_key(seed);
        let stamp = unix_now();
        ClientMessage::ReferralStatus {
            client_id: client_id.into(),
            public_key: Some(public),
            proof: Some(signed(&signing, "status", client_id, stamp)),
            proof_time: Some(stamp),
        }
    }

    fn redeem_request(seed: u8, client_id: &str, code: &str) -> ClientMessage {
        let (signing, public) = device_key(seed);
        let stamp = unix_now();
        ClientMessage::RedeemReferral {
            client_id: client_id.into(),
            code: code.into(),
            public_key: Some(public),
            proof: Some(signed(&signing, &format!("redeem:{code}"), client_id, stamp)),
            proof_time: Some(stamp),
        }
    }

    fn quota_settings() -> Settings {
        settings_with(Arc::new(QuotaTracker::new(PlanAllowances::default(), Default::default())))
    }

    #[tokio::test]
    async fn a_proved_device_is_given_a_code_and_a_friend_can_redeem_it() {
        let settings = quota_settings();
        let Some(ServerMessage::Referral { code, bonus_seconds: 0, .. }) =
            ask(&settings, status_request(1, "owner-phone")).await
        else {
            panic!("expected a code with no bonus yet");
        };

        let reply = ask(&settings, redeem_request(2, "friend-phone", &code)).await;
        assert!(matches!(
            reply,
            Some(ServerMessage::Referral { bonus_seconds: 1800, redeemed: true, .. })
        ), "got {reply:?}");

        // The bonus is on the key the friend proves, and is what the quota check reads.
        let (_, friend_key) = device_key(2);
        assert_eq!(settings.quota.remaining(&friend_key, None, Plan::Free), Some(1800 + 1800));
        let (_, owner_key) = device_key(1);
        assert_eq!(settings.quota.remaining(&owner_key, None, Plan::Free), Some(1800 + 1800));
    }

    #[tokio::test]
    async fn an_invite_request_without_a_proof_is_refused() {
        let settings = quota_settings();
        let reply = ask(
            &settings,
            ClientMessage::ReferralStatus {
                client_id: "phone".into(),
                public_key: None,
                proof: None,
                proof_time: None,
            },
        )
        .await;
        assert!(matches!(reply, Some(ServerMessage::Error { ref code, .. }) if code == "proofRequired"));
    }

    #[tokio::test]
    async fn a_redemption_signed_for_another_code_is_refused() {
        let settings = quota_settings();
        let Some(ServerMessage::Referral { code, .. }) =
            ask(&settings, status_request(1, "owner-phone")).await
        else {
            panic!("expected a code");
        };
        let ClientMessage::RedeemReferral { client_id, public_key, proof, proof_time, .. } =
            redeem_request(2, "friend-phone", "AAAAAAAA")
        else {
            unreachable!()
        };
        let reply = ask(
            &settings,
            ClientMessage::RedeemReferral { client_id, code, public_key, proof, proof_time },
        )
        .await;
        assert!(matches!(reply, Some(ServerMessage::Error { ref code, .. }) if code == "proofInvalid"));
    }

    #[tokio::test]
    async fn redeeming_twice_or_your_own_code_is_refused() {
        let settings = quota_settings();
        let Some(ServerMessage::Referral { code, .. }) =
            ask(&settings, status_request(1, "owner-phone")).await
        else {
            panic!("expected a code");
        };
        let own = ask(&settings, redeem_request(1, "owner-phone", &code)).await;
        assert!(matches!(own, Some(ServerMessage::Error { ref code, .. }) if code == "referralOwnCode"));

        ask(&settings, redeem_request(2, "friend-phone", &code)).await;
        let again = ask(&settings, redeem_request(2, "friend-phone", &code)).await;
        assert!(matches!(again, Some(ServerMessage::Error { ref code, .. }) if code == "referralAlreadyRedeemed"));
    }

    #[tokio::test]
    async fn a_connection_that_keeps_asking_is_told_to_reconnect() {
        let settings = quota_settings();
        let (tx, _rx) = channel();
        let registry = Arc::new(Registry::new(usize::MAX));
        let hosts = HostRegistry::new();
        let mut state = ConnectionState::default();
        let mut last = None;
        for _ in 0..=MAX_REFERRAL_REQUESTS_PER_CONNECTION {
            last = dispatch(status_request(1, "p"), &tx, &registry, &hosts, &settings, "127.0.0.1", &mut state).await;
        }
        assert!(matches!(last, Some(ServerMessage::Error { ref code, .. }) if code == "tooManyRequests"));
    }

    /// The port every session is told to send video to. A fixed number rather than a bound socket:
    /// what these tests are about is what signalling *says*, and the port it says it on is decided
    /// at startup and belongs to `udp_relay`'s own tests and to the end-to-end ones.
    const VIDEO_PORT: u16 = 30190;

    fn settings_with(quota: Arc<QuotaTracker>) -> Settings {
        Settings {
            host: None,
            public_control_port: 9443,
            video_port: VIDEO_PORT,
            session_ttl: Duration::from_secs(60),
            quota,
            // Pinned to Apple's real root, so a receipt in these tests verifies only if someone
            // has Apple's signing key. The receipt path itself is exercised in `storekit`'s own
            // tests, where the chain is one the test can actually sign with.
            receipts: Arc::new(StoreKitVerifier::apple(true)),
            // Open by default, because almost every test here is about something else and a
            // ceiling that refuses sessions would show up as a mystery failure in all of them.
            // The ceilings have their own tests, below.
            max_sessions: usize::MAX,
            max_connections: usize::MAX,
            handshake_timeout: Duration::from_secs(10),
            idle_timeout: Duration::from_secs(90),
            apns: None,
            fcm: None,
            play: None,
            limiter: Arc::new(crate::limits::PeerLimiter::default()),
            require_proven_hosts: false,
            activity_budget: Default::default(),
        }
    }

    /// The allowances the app states, which are the relay's defaults: 30 minutes free and no limit
    /// on paid plans.
    fn default_settings() -> Settings {
        settings_with(Arc::new(QuotaTracker::new(
            PlanAllowances::default(),
            Default::default(),
        )))
    }

    fn activity_message(token: &str) -> ClientMessage {
        serde_json::from_str(&format!(
            r#"{{"type":"notifyActivity","activityToken":"{token}","activity":"session","event":"update","contentState":{{"n":1}}}}"#
        ))
        .expect("parses")
    }

    async fn ask_as_host(state: &mut ConnectionState, message: ClientMessage) -> Option<ServerMessage> {
        let (tx, _rx) = channel();
        let registry = Arc::new(Registry::new(usize::MAX));
        dispatch(message, &tx, &registry, &HostRegistry::new(), &default_settings(), "127.0.0.1", state).await
    }

    #[tokio::test]
    async fn an_unregistered_connection_may_not_push_an_activity() {
        let reply = ask(&default_settings(), activity_message(&"ab".repeat(32))).await;
        assert!(matches!(reply, Some(ServerMessage::Error { ref code, .. }) if code == "unauthorized"));
    }

    #[tokio::test]
    async fn a_registered_host_without_apns_is_told_the_push_is_unavailable() {
        let mut state = ConnectionState { registered_as: Some("mac".into()), ..Default::default() };
        let reply = ask_as_host(&mut state, activity_message(&"ab".repeat(32))).await;
        assert_eq!(reply, Some(ServerMessage::ActivityRefused { reason: ActivityRefusal::Unavailable, request_id: None }));
    }

    #[tokio::test]
    async fn a_bad_activity_token_or_an_fcm_token_is_refused_as_an_invalid_token() {
        let mut state = ConnectionState { registered_as: Some("mac".into()), ..Default::default() };
        let fcm = crate::protocol::bytes_hex(b"fcm:abc123");
        for token in ["zz", fcm.as_str()] {
            let reply = ask_as_host(&mut state, activity_message(token)).await;
            assert_eq!(reply, Some(ServerMessage::ActivityRefused { reason: ActivityRefusal::InvalidToken, request_id: None }));
        }
    }

    #[tokio::test]
    async fn pushes_past_the_burst_are_dropped_without_a_reply() {
        let mut state = ConnectionState { registered_as: Some("mac".into()), ..Default::default() };
        let token = "ab".repeat(32);
        for _ in 0..5 {
            assert!(ask_as_host(&mut state, activity_message(&token)).await.is_some());
        }
        assert_eq!(ask_as_host(&mut state, activity_message(&token)).await, None);
    }

    #[tokio::test]
    async fn a_token_cannot_be_hammered_through_many_connections() {
        let settings = default_settings();
        let token = "ab".repeat(32);
        let (tx, _rx) = channel();
        let registry = Arc::new(Registry::new(usize::MAX));
        let mut answered = 0;
        for _ in 0..20 {
            let mut state = ConnectionState { registered_as: Some("mac".into()), ..Default::default() };
            let reply = dispatch(activity_message(&token), &tx, &registry, &HostRegistry::new(), &settings, "127.0.0.1", &mut state).await;
            answered += usize::from(reply.is_some());
        }
        assert_eq!(answered, 5, "a new connection each time does not reset the token's budget");
    }

    #[test]
    fn a_refusal_serialises_with_a_reason_from_the_closed_set_and_nothing_else() {
        let json = serde_json::to_string(&ServerMessage::ActivityRefused { reason: ActivityRefusal::InvalidToken, request_id: None }).unwrap();
        assert_eq!(json, r#"{"type":"activityRefused","reason":"invalidToken"}"#);
    }

    #[test]
    fn a_refusal_echoes_the_request_id_verbatim() {
        let refused = ServerMessage::ActivityRefused { reason: ActivityRefusal::Rejected, request_id: Some("r-7".into()) };
        assert_eq!(serde_json::to_string(&refused).unwrap(), r#"{"type":"activityRefused","reason":"rejected","requestId":"r-7"}"#);
    }

    #[tokio::test]
    async fn a_synchronous_refusal_carries_the_pushs_request_id() {
        let mut state = ConnectionState { registered_as: Some("mac".into()), ..Default::default() };
        let ClientMessage::NotifyActivity(mut push) = activity_message("zz") else { panic!("not a notifyActivity") };
        push.request_id = Some("r-9".into());
        let reply = ask_as_host(&mut state, ClientMessage::NotifyActivity(push)).await;
        assert_eq!(reply, Some(ServerMessage::ActivityRefused { reason: ActivityRefusal::InvalidToken, request_id: Some("r-9".into()) }));
    }

    #[tokio::test]
    async fn a_registered_host_can_be_looked_up() {
        let hosts = HostRegistry::new();
        let (tx, _rx) = channel();
        hosts
            .put("mac", 3, tx, None)
            .await
            .expect("an unproved registration is accepted while nothing is bound");

        let host = hosts.entry_for("mac").await.expect("should be found");
        assert_eq!(host.protocol_version, 3);
        assert!(hosts.entry_for("other").await.is_none());
        assert_eq!(hosts.online_count().await, 1);
    }

    #[tokio::test]
    async fn a_replaced_host_is_not_evicted_by_its_predecessors_cleanup() {
        // The laptop-changes-networks case. The old signalling socket closes *after* the new one
        // registered, so cleanup for the old must not take the new registration with it.
        let hosts = HostRegistry::new();
        let (old_tx, _old_rx) = channel();
        let (new_tx, _new_rx) = channel();

        hosts
            .put("mac", 3, old_tx.clone(), None)
            .await
            .expect("an unproved registration is accepted while nothing is bound");
        hosts
            .put("mac", 3, new_tx.clone(), None)
            .await
            .expect("an unproved registration is accepted while nothing is bound");

        hosts.remove_if_ours("mac", &old_tx).await;
        assert_eq!(
            hosts.online_count().await,
            1,
            "the stale connection must not unregister the live one"
        );

        hosts.remove_if_ours("mac", &new_tx).await;
        assert_eq!(hosts.online_count().await, 0, "the real owner still can");
    }

    #[tokio::test]
    async fn presence_is_answered_from_the_registry() {
        let registry = Arc::new(Registry::new(usize::MAX));
        let hosts = HostRegistry::new();
        let (host_tx, _host_rx) = channel();
        hosts
            .put("mac", 3, host_tx, None)
            .await
            .expect("an unproved registration is accepted while nothing is bound");

        let settings = default_settings();

        let answer = |host_id: &str, hosts: &HostRegistry, registry: &Arc<Registry>| {
            let hosts = hosts.clone();
            let registry = Arc::clone(registry);
            let settings = settings.clone();
            let (tx, _rx) = channel();
            let host_id = host_id.to_string();
            async move {
                dispatch(
                    ClientMessage::HostPresence { host_id: host_id.clone() },
                    &tx,
                    &registry,
                    &hosts,
                    &settings,
                    "127.0.0.1",
                    &mut ConnectionState::default(),
                )
                .await
            }
        };

        assert_eq!(
            answer("mac", &hosts, &registry).await,
            Some(ServerMessage::HostPresence { host_id: "mac".into(), online: true })
        );
        assert_eq!(
            answer("ghost", &hosts, &registry).await,
            Some(ServerMessage::HostPresence { host_id: "ghost".into(), online: false }),
            "an unregistered Mac is answered, not refused: the phone asked a question and no is an answer"
        );

        // And asking opens nothing. The whole point of a presence query over the app's old
        // approach of simply trying to connect is that it does not cost a session.
        assert_eq!(registry.len().await, 0, "presence must not allocate a session");
    }

    /// The answer follows the registration, so a Mac that has gone is reported gone.
    #[tokio::test]
    async fn a_mac_that_has_gone_is_reported_offline() {
        let registry = Arc::new(Registry::new(usize::MAX));
        let hosts = HostRegistry::new();
        let (host_tx, _host_rx) = channel();
        hosts
            .put("mac", 3, host_tx.clone(), None)
            .await
            .expect("an unproved registration is accepted while nothing is bound");

        let settings = default_settings();
        let ask = |hosts: &HostRegistry, registry: &Arc<Registry>, settings: &Settings| {
            let hosts = hosts.clone();
            let registry = Arc::clone(registry);
            let settings = settings.clone();
            async move {
                let (tx, _rx) = channel();
                dispatch(
                    ClientMessage::HostPresence { host_id: "mac".into() },
                    &tx,
                    &registry,
                    &hosts,
                    &settings,
                    "127.0.0.1",
                    &mut ConnectionState::default(),
                )
                .await
            }
        };

        assert!(matches!(
            ask(&hosts, &registry, &settings).await,
            Some(ServerMessage::HostPresence { online: true, .. })
        ));

        // The Mac's socket dropping is what a laptop changing networks looks like from here.
        hosts.remove_if_ours("mac", &host_tx).await;

        assert_eq!(
            ask(&hosts, &registry, &settings).await,
            Some(ServerMessage::HostPresence { host_id: "mac".into(), online: false })
        );
    }

    #[tokio::test]
    async fn asking_for_an_unknown_host_reports_it_offline() {
        let registry = Arc::new(Registry::new(usize::MAX));
        let hosts = HostRegistry::new();
        let settings = default_settings();
        let (tx, _rx) = channel();
        let mut state = ConnectionState::default();

        let reply = dispatch(
            ClientMessage::ConnectToHost {
                host_id: "ghost".into(),
                client_id: "phone".into(),
                protocol_version: 3,
                api_key: None,
                plan: None,
                jws_representation: None,
                public_key: None,
                proof: None,
                proof_time: None,
                play_purchase_token: None,
                play_product_id: None,
            },
            &tx,
            &registry,
            &hosts,
            &settings,
            "127.0.0.1",
            &mut state,
        )
        .await;

        assert_eq!(
            reply,
            Some(ServerMessage::HostOffline {
                device_id: "ghost".into()
            })
        );
        assert_eq!(registry.len().await, 0, "no session should be left behind");
    }

    #[tokio::test]
    async fn a_version_mismatch_is_refused_before_any_session_exists() {
        let registry = Arc::new(Registry::new(usize::MAX));
        let hosts = HostRegistry::new();
        let (host_tx, _host_rx) = channel();
        hosts
            .put("mac", 3, host_tx, None)
            .await
            .expect("an unproved registration is accepted while nothing is bound");

        let settings = default_settings();
        let (tx, _rx) = channel();
        let mut state = ConnectionState::default();

        let reply = dispatch(
            ClientMessage::ConnectToHost {
                host_id: "mac".into(),
                client_id: "phone".into(),
                protocol_version: 2,
                api_key: None,
                plan: None,
                jws_representation: None,
                public_key: None,
                proof: None,
                proof_time: None,
                play_purchase_token: None,
                play_product_id: None,
            },
            &tx,
            &registry,
            &hosts,
            &settings,
            "127.0.0.1",
            &mut state,
        )
        .await;

        assert!(matches!(reply, Some(ServerMessage::Error { .. })));
        assert_eq!(registry.len().await, 0);
    }

    #[tokio::test]
    async fn connecting_reaches_the_mac_as_well_as_the_phone() {
        let registry = Arc::new(Registry::new(usize::MAX));
        let hosts = HostRegistry::new();
        let (host_tx, mut host_rx) = channel();
        hosts
            .put("mac", 3, host_tx, None)
            .await
            .expect("an unproved registration is accepted while nothing is bound");

        let settings = default_settings();
        let (tx, _rx) = channel();
        let mut state = ConnectionState::default();

        let reply = dispatch(
            ClientMessage::ConnectToHost {
                host_id: "mac".into(),
                client_id: "phone".into(),
                protocol_version: 3,
                api_key: None,
                plan: None,
                jws_representation: None,
                public_key: None,
                proof: None,
                proof_time: None,
                play_purchase_token: None,
                play_product_id: None,
            },
            &tx,
            &registry,
            &hosts,
            &settings,
            "relay.test",
            &mut state,
        )
        .await;

        // The phone is told where to go...
        let ready = match reply.expect("the phone should get a session") {
            ServerMessage::SessionReady {
                control_host,
                control_port,
                video_host,
                video_port,
                control_token,
                video_token,
                remaining_seconds: _,
            } => (control_host, control_port, video_host, video_port, control_token, video_token),
            other => panic!("expected a session, got {other:?}"),
        };
        assert_eq!(ready.0, "relay.test");
        assert_eq!(ready.1, 9443);
        assert_eq!(
            ready.3, VIDEO_PORT,
            "the session is told the one port the shared socket is on"
        );

        // ...and so is the Mac, which never asked. Everything matches except the video token —
        // the two ends have to be distinguishable, so that a re-bind from one cannot move the
        // other's address.
        let Some(ServerMessage::SessionReady {
            control_host,
            control_port,
            video_host,
            video_port,
            control_token,
            video_token,
            remaining_seconds: _,
        }) = host_rx.recv().await
        else {
            panic!("the Mac should be pushed a session too");
        };

        assert_eq!((control_host, control_port), (ready.0, ready.1));
        assert_eq!((video_host, video_port), (ready.2, ready.3));
        assert_eq!(control_token, ready.4);
        assert_ne!(video_token, ready.5, "the two ends must not share a token");
    }

    /// Sends one connect request against a Mac that is registered and a counter that is already
    /// spent, and reports what the phone was told.
    async fn connect_with(plan: Option<&str>, spent_seconds: u64) -> Option<ServerMessage> {
        let quota = Arc::new(QuotaTracker::new(PlanAllowances::default(), Default::default()));
        // Recorded rather than configured away, so the test travels the same path a client does.
        quota.record("phone", Duration::from_secs(spent_seconds));
        connect_against(quota, plan).await
    }

    async fn connect_against(quota: Arc<QuotaTracker>, plan: Option<&str>) -> Option<ServerMessage> {
        let registry = Arc::new(Registry::new(usize::MAX));
        let hosts = HostRegistry::new();
        let (host_tx, _host_rx) = channel();
        hosts
            .put("mac", 3, host_tx, None)
            .await
            .expect("an unproved registration is accepted while nothing is bound");

        let settings = settings_with(quota);

        let (tx, _rx) = channel();
        let mut state = ConnectionState::default();
        dispatch(
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
                play_purchase_token: None,
                play_product_id: None,
            },
            &tx,
            &registry,
            &hosts,
            &settings,
            "127.0.0.1",
            &mut state,
        )
        .await
    }

    fn remaining_in(reply: Option<ServerMessage>) -> Option<u64> {
        match reply {
            Some(ServerMessage::SessionReady { remaining_seconds, .. }) => remaining_seconds,
            other => panic!("expected a session, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn a_free_session_reports_what_is_left_of_the_allowance() {
        let reply = connect_with(None, 100).await;
        assert_eq!(remaining_in(reply), Some(30 * 60 - 100));
    }

    #[tokio::test]
    async fn a_paid_plan_session_omits_the_remaining_seconds() {
        for plan in ["relay", "plus", "pro"] {
            let reply = connect_with(Some(plan), 100).await;
            assert_eq!(remaining_in(reply), None, "{plan}");
        }
    }

    #[tokio::test]
    async fn an_unlimited_allowance_omits_the_remaining_seconds() {
        let allowances = PlanAllowances { free_seconds: None, ..PlanAllowances::default() };
        let quota = Arc::new(QuotaTracker::new(allowances, Default::default()));
        assert_eq!(remaining_in(connect_against(quota, None).await), None);
    }

    #[tokio::test]
    async fn a_referral_bonus_is_included_in_the_remaining_seconds() {
        let referrals = Arc::new(Referrals::in_memory(ReferralTerms::default()));
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let code = referrals.standing("owner", now).unwrap().code;
        referrals.redeem("phone", &code, now).unwrap();
        let quota = Arc::new(
            QuotaTracker::new(PlanAllowances::default(), Default::default()).with_referrals(referrals),
        );
        quota.record("phone", Duration::from_secs(1000));
        let bonus = ReferralTerms::default().bonus_seconds;
        assert_eq!(remaining_in(connect_against(quota, None).await), Some(30 * 60 + bonus - 1000));
    }

    /// 30 minutes free means 30 minutes: a client that has spent more than that is refused.
    #[tokio::test]
    async fn a_spent_free_allowance_is_refused() {
        let reply = connect_with(None, 30 * 60 + 1).await;
        assert!(
            matches!(reply, Some(ServerMessage::Error { ref code, .. }) if code == "quotaExceeded"),
            "expected a quota refusal, got {reply:?}"
        );
    }

    /// The same client, saying `relay`, is not metered at all — which is the whole of what a
    /// subscription buys here.
    #[tokio::test]
    async fn a_relay_plan_is_not_metered() {
        let reply = connect_with(Some("relay"), 100 * 3600).await;
        assert!(
            matches!(reply, Some(ServerMessage::SessionReady { .. })),
            "Relay should be unlimited: {reply:?}"
        );
    }

    /// And a client saying `pro` is not blocked by the counter at all.
    #[tokio::test]
    async fn a_pro_plan_is_not_blocked_by_its_counter() {
        for plan in ["plus", "pro"] {
            let reply = connect_with(Some(plan), 100 * 3600).await;
            assert!(
                matches!(reply, Some(ServerMessage::SessionReady { .. })),
                "{plan} should not be metered, got {reply:?}"
            );
        }
    }

    /// The trust boundary, stated as a test: the plan is the client's word, so the only defence
    /// is that an unrecognised word buys nothing. `pro` spelled any other way is free.
    #[tokio::test]
    async fn a_plan_the_relay_does_not_know_is_metered_as_free() {
        for claimed in ["enterprise", "unlimited", "pro max", ""] {
            let reply = connect_with(Some(claimed), 30 * 60 + 1).await;
            assert!(
                matches!(reply, Some(ServerMessage::Error { ref code, .. }) if code == "quotaExceeded"),
                "{claimed:?} should have been metered as free, got {reply:?}"
            );
        }
    }

    fn register(device_id: &str, proved: bool) -> ClientMessage {
        let (signing, public) = device_key(9);
        let stamp = unix_now();
        let body = device_proof::payload(device_id, stamp);
        let signature: Signature = signing.sign(body.as_bytes());
        ClientMessage::RegisterHost {
            device_id: device_id.into(),
            name: "Studio".into(),
            protocol_version: 3,
            public_key: proved.then_some(public),
            proof: proved.then(|| crate::protocol::bytes_hex(signature.to_der().as_bytes())),
            proof_time: proved.then_some(stamp),
        }
    }

    fn connect_to(host_id: &str) -> ClientMessage {
        serde_json::from_str(&format!(
            r#"{{"type":"connectToHost","hostId":"{host_id}","clientId":"phone","protocolVersion":3,"plan":"free"}}"#
        ))
        .expect("parses")
    }

    #[tokio::test]
    async fn a_second_registration_on_one_connection_replaces_the_first() {
        let hosts = HostRegistry::new();
        let registry = Arc::new(Registry::new(usize::MAX));
        let settings = default_settings();
        let (tx, _rx) = channel();
        let mut state = ConnectionState::default();

        for id in ["one", "two"] {
            let reply = dispatch(register(id, false), &tx, &registry, &hosts, &settings, "127.0.0.1", &mut state).await;
            assert!(matches!(reply, Some(ServerMessage::Registered { .. })));
        }

        assert!(hosts.entry_for("one").await.is_none(), "the earlier id must not linger");
        assert!(hosts.entry_for("two").await.is_some());
        assert_eq!(hosts.online_count().await, 1);
    }

    #[tokio::test]
    async fn a_host_whose_connection_is_gone_is_not_present_even_if_cleanup_never_ran() {
        let hosts = HostRegistry::new();
        let (tx, rx) = channel();
        hosts.put("mac", 3, tx, None).await.unwrap();
        assert!(hosts.entry_for("mac").await.is_some());

        drop(rx);
        assert_eq!(hosts.online_count().await, 0);
        assert!(hosts.entry_for("mac").await.is_none());
    }

    #[tokio::test]
    async fn only_a_proven_host_can_be_connected_to_when_proof_is_required() {
        let hosts = HostRegistry::new();
        let registry = Arc::new(Registry::new(usize::MAX));
        let mut settings = default_settings();
        settings.require_proven_hosts = true;
        let (host_tx, _host_rx) = channel();
        let mut host_state = ConnectionState::default();
        for (id, proved) in [("old", false), ("new", true)] {
            dispatch(register(id, proved), &host_tx, &registry, &hosts, &settings, "127.0.0.1", &mut host_state).await;
        }
        // Registered under one connection, the second replaced the first, so register "old" again
        // on its own connection.
        let (old_tx, _old_rx) = channel();
        dispatch(register("old", false), &old_tx, &registry, &hosts, &settings, "127.0.0.1", &mut ConnectionState::default()).await;

        let (tx, _rx) = channel();
        let mut state = ConnectionState::default();
        let unproven = dispatch(connect_to("old"), &tx, &registry, &hosts, &settings, "127.0.0.1", &mut state).await;
        assert_eq!(unproven, Some(ServerMessage::HostOffline { device_id: "old".into() }));
        let proven = dispatch(connect_to("new"), &tx, &registry, &hosts, &settings, "127.0.0.1", &mut state).await;
        assert!(matches!(proven, Some(ServerMessage::SessionReady { .. })), "got {proven:?}");
    }

    #[tokio::test]
    async fn an_address_over_its_allocation_rate_or_unspliced_cap_is_refused_before_allocating() {
        let hosts = HostRegistry::new();
        let registry = Arc::new(Registry::new(usize::MAX));
        let mut settings = default_settings();
        settings.limiter = Arc::new(PeerLimiter::new(crate::limits::IpLimits {
            exempt_loopback: false,
            unspliced_sessions: 1,
            ..Default::default()
        }));
        let (host_tx, _host_rx) = mpsc::channel(8);
        hosts.put("mac", 3, host_tx, None).await.unwrap();

        let (tx, _rx) = channel();
        let mut state = ConnectionState { peer: Some("203.0.113.4".parse().unwrap()), ..Default::default() };
        let first = dispatch(connect_to("mac"), &tx, &registry, &hosts, &settings, "127.0.0.1", &mut state).await;
        assert!(matches!(first, Some(ServerMessage::SessionReady { .. })));

        let mut other = ConnectionState { peer: Some("203.0.113.4".parse().unwrap()), ..Default::default() };
        let refused = dispatch(
            serde_json::from_str(r#"{"type":"connectToHost","hostId":"mac","clientId":"second","protocolVersion":3,"plan":"free"}"#).unwrap(),
            &tx, &registry, &hosts, &settings, "127.0.0.1", &mut other,
        )
        .await;
        assert!(matches!(refused, Some(ServerMessage::Error { ref code, .. }) if code == "tooManySessions"));
        assert_eq!(registry.len().await, 1, "nothing was allocated for the refused one");
    }

    #[tokio::test]
    async fn a_client_that_stops_reading_is_dropped_by_the_write_timeout() {
        let (server_end, client_end) = tokio::io::duplex(256);
        let mut settings = default_settings();
        settings.handshake_timeout = Duration::from_millis(300);
        settings.idle_timeout = Duration::from_secs(60);
        let server = tokio::spawn(handle(
            server_end,
            None,
            "127.0.0.1".into(),
            Arc::new(Registry::new(usize::MAX)),
            HostRegistry::new(),
            settings,
        ));

        let (mut ws, _) = tokio_tungstenite::client_async("ws://localhost/", client_end).await.unwrap();
        let ping = serde_json::to_string(&ClientMessage::Ping).unwrap();
        // Replies pile up in a 256 byte pipe nobody reads. The client is kept alive until the end
        // so a pass cannot be the server noticing a close.
        let flood = tokio::spawn(async move {
            for _ in 0..400 {
                if ws.send(Message::Text(ping.clone().into())).await.is_err() {
                    break;
                }
            }
            ws
        });

        let finished = time::timeout(Duration::from_secs(3), server).await;
        assert!(finished.is_ok(), "a peer that never reads must not hold the connection past the write timeout");
        flood.abort();
    }

    fn real_ip_headers(value: &str) -> http::HeaderMap {
        let mut map = http::HeaderMap::new();
        map.insert("x-real-ip", value.parse().unwrap());
        map
    }

    #[test]
    fn forwarded_v6_clients_are_limited_by_their_prefix() {
        let limiter = Arc::new(PeerLimiter::new(crate::limits::IpLimits {
            signalling_connections: 1,
            ..Default::default()
        }));
        let loopback: IpAddr = "127.0.0.1".parse().unwrap();
        let first = forwarded_address(loopback, &real_ip_headers("2001:db8:5:6::1"), ClientIpHeader::XRealIp).unwrap();
        let sibling = forwarded_address(loopback, &real_ip_headers("2001:db8:5:6:aaaa::2"), ClientIpHeader::XRealIp).unwrap();
        let _held = limiter.admit_signalling(first).unwrap();
        assert!(limiter.admit_signalling(sibling).is_none());
    }
}
