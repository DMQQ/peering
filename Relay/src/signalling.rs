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
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::Message;
use tracing::{debug, info, warn};

use crate::protocol::{hex, unhex, ClientMessage, ServerMessage};
use crate::quota::{Plan, QuotaTracker};
use crate::session::{CLIENT_SLOT, HOST_SLOT, Registry, Token};
use crate::storekit::{ReceiptCache, StoreKitVerifier};

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
}

/// What one signalling connection carries from message to message.
#[derive(Default)]
struct ConnectionState {
    /// The device ID this socket registered as, so the registration can be removed when it closes.
    registered_as: Option<String>,
    /// The verdict on the receipts this client has sent, so a JWS is verified once per session
    /// rather than once per message. See `storekit::ReceiptCache`.
    receipts: ReceiptCache,
}

/// The Macs that are currently registered, by device ID.
#[derive(Clone, Default)]
pub struct HostRegistry {
    inner: Arc<Mutex<HashMap<String, Host>>>,
}

struct Host {
    name: String,
    protocol_version: u16,
    /// The push channel for this Mac's signalling connection.
    tx: mpsc::Sender<ServerMessage>,
}

/// A host's registration, cloned out of the registry so the lock is not held while a session is
/// allocated underneath it.
struct HostRef {
    tx: mpsc::Sender<ServerMessage>,
    name: String,
    protocol_version: u16,
}

impl HostRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    async fn put(&self, device_id: &str, name: String, version: u16, tx: mpsc::Sender<ServerMessage>) {
        self.inner.lock().await.insert(
            device_id.to_string(),
            Host {
                name,
                protocol_version: version,
                tx,
            },
        );
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

    async fn entry_for(&self, device_id: &str) -> Option<HostRef> {
        self.inner.lock().await.get(device_id).map(|host| HostRef {
            tx: host.tx.clone(),
            name: host.name.clone(),
            protocol_version: host.protocol_version,
        })
    }

    pub async fn online_count(&self) -> usize {
        self.inner.lock().await.len()
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
    info!(addr = %listener.local_addr().map(|a| a.to_string()).unwrap_or_default(), "signalling listening");

    loop {
        let (stream, peer) = match listener.accept().await {
            Ok(pair) => pair,
            Err(error) => {
                warn!(%error, "signalling listener could not accept");
                continue;
            }
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
                    match acceptor.accept(stream).await {
                        Ok(secured) => {
                            handle(secured, peer, relay_host, registry, hosts, settings).await
                        }
                        Err(error) => debug!(%peer, %error, "signalling TLS handshake failed"),
                    }
                });
            }
            None => {
                tokio::spawn(async move {
                    handle(stream, peer, relay_host, registry, hosts, settings).await
                });
            }
        }
    }
}

async fn handle<S>(
    stream: S,
    peer: SocketAddr,
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
    let ws = match tokio_tungstenite::accept_async_with_config(stream, Some(config)).await {
        Ok(ws) => ws,
        Err(error) => {
            debug!(%peer, %error, "websocket handshake failed");
            return;
        }
    };

    let (mut sink, mut source) = ws.split();

    // Every outgoing message goes through here, including replies to the message being handled.
    // That is what lets the select below own `sink` exclusively: a reply written straight to the
    // sink from the read arm would need it borrowed in both arms at once.
    let (tx, mut rx) = mpsc::channel::<ServerMessage>(32);
    let mut state = ConnectionState::default();

    loop {
        tokio::select! {
            incoming = source.next() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        let reply = match serde_json::from_str::<ClientMessage>(&text) {
                            Ok(message) => {
                                dispatch(message, &tx, &registry, &hosts, &settings, &relay_host, &mut state).await
                            }
                            Err(error) => {
                                debug!(%peer, %error, "unparseable signalling message");
                                Some(ServerMessage::error("protocol", "unrecognised message"))
                            }
                        };
                        if let Some(message) = reply {
                            // A full channel here would mean 32 queued replies to a client that is
                            // not reading, which is already a client we are about to drop.
                            let _ = tx.send(message).await;
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => break,
                    // Ping, Pong and Binary are not part of this conversation. tungstenite answers
                    // protocol-level pings itself, so there is nothing to do for them here.
                    Some(Ok(_)) => {}
                    Some(Err(error)) => {
                        debug!(%peer, %error, "signalling read failed");
                        break;
                    }
                }
            }

            outgoing = rx.recv() => {
                let Some(message) = outgoing else { break };
                let Ok(json) = serde_json::to_string(&message) else { continue };
                if sink.send(Message::Text(json.into())).await.is_err() {
                    break;
                }
            }
        }
    }

    if let Some(device_id) = state.registered_as {
        hosts.remove_if_ours(&device_id, &tx).await;
        info!(%device_id, "host went offline");
    }
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
        } => {
            if device_id.len() > MAX_FIELD || name.len() > MAX_FIELD {
                return Some(ServerMessage::error("invalid", "field too long"));
            }
            hosts
                .put(&device_id, name.clone(), protocol_version, self_tx.clone())
                .await;
            state.registered_as = Some(device_id.clone());
            info!(%device_id, %name, protocol_version, "host registered");
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
        } => {
            if host_id.len() > MAX_FIELD || client_id.len() > MAX_FIELD {
                return Some(ServerMessage::error("invalid", "field too long"));
            }
            if let Some(api_key) = &api_key {
                if api_key.len() > MAX_FIELD {
                    return Some(ServerMessage::error("invalid", "field too long"));
                }
            }

            // The plan is resolved before anything is allocated, and the raw strings are dropped
            // here: what travels on is the resolved plan and how it was arrived at, so nothing
            // downstream can be tempted to read a name this relay does not know, or to treat a
            // receipt as proof without having verified it. The receipt is verified at most once per
            // connection, which is what `ReceiptCache` is for, and it is never logged.
            let claimed = Plan::from_wire(plan.as_deref());
            let resolved = state.receipts.resolve(
                &settings.receipts,
                claimed,
                jws_representation.as_deref(),
            );
            let plan = resolved.plan;

            // One line, and only when a receipt was sent and refused: it is the answer to "why is
            // this client metered as free", and it is the evidence an operator collects with
            // PEERINGD_TRUST_CLAIMED_PLANS=0 before turning the fallback off.
            if let Some(rejected) = resolved.rejected {
                info!(
                    %client_id,
                    plan = plan.as_str(),
                    plan_trust = resolved.trust.as_str(),
                    reason = rejected.reason(),
                    "receipt refused"
                );
            }

            // Check relay quota before allocating a session. Paid keys bypass the counter; a plan
            // with an allowance is blocked when its allowance for this window is exhausted, and
            // the two unlimited plans are not blocked at all.
            let remaining = settings.quota.remaining(&client_id, api_key.as_deref(), plan);
            if remaining == Some(0) {
                // Logged because it is the line an operator is asked about: "why was I cut off"
                // is answered here, with the plan that was applied, whether Apple or the client
                // said so, and so whether the client was metered as free when it did not think
                // it was.
                info!(
                    %client_id,
                    plan = plan.as_str(),
                    plan_trust = resolved.trust.as_str(),
                    "relay allowance exhausted"
                );
                return Some(ServerMessage::error(
                    "quotaExceeded",
                    "relay allowance exhausted for this period",
                ));
            }

            let Some(host) = hosts.entry_for(&host_id).await else {
                debug!(%host_id, "asked for a host that is not registered");
                return Some(ServerMessage::HostOffline { device_id: host_id });
            };

            // Checked here so a mismatched pair is told before either end spends a round trip on a
            // handshake that would fail anyway. The two ends check it again themselves — this is a
            // courtesy, not the enforcement.
            if host.protocol_version != protocol_version {
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
            let allocated = registry.allocate(&host_id, &client_id).await;

            // The name is here because it is the one thing that makes this log line useful to
            // whoever is running the relay: a device ID identifies a machine to a database, and a
            // name identifies it to a person reading `journalctl`. The plan is here because it is
            // what decides whether this session is metered at all, and an operator reading a
            // session back needs that settled by the line rather than inferred from the client —
            // which is what `plan_trust` is for: `verified` means Apple signed the plan, `claimed`
            // means the client's word for it, `neither` means the free allowance.
            info!(
                %host_id,
                host_name = %host.name,
                %client_id,
                video_port = settings.video_port,
                plan = plan.as_str(),
                plan_trust = resolved.trust.as_str(),
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
            };

            // Pushed to the Mac first. It did not ask for this, so a failure here means the Mac has
            // gone away between registering and now — reported to the phone rather than leaving it
            // waiting on a session the other end will never join.
            if host
                .tx
                .send(ready(allocated.video_tokens[HOST_SLOT]))
                .await
                .is_err()
            {
                debug!(%host_id, "host push failed");
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

        ClientMessage::Ping => Some(ServerMessage::Pong),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::PlanAllowances;

    fn channel() -> (mpsc::Sender<ServerMessage>, mpsc::Receiver<ServerMessage>) {
        mpsc::channel(4)
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
        }
    }

    /// The allowances the app states, which are the relay's defaults: half an hour free and three
    /// hours on Relay. Two numbers rather than one, so a test that confuses the plans fails.
    fn default_settings() -> Settings {
        settings_with(Arc::new(QuotaTracker::new(
            PlanAllowances::default(),
            Default::default(),
        )))
    }

    #[tokio::test]
    async fn a_registered_host_can_be_looked_up() {
        let hosts = HostRegistry::new();
        let (tx, _rx) = channel();
        hosts.put("mac", "Studio".into(), 3, tx).await;

        let host = hosts.entry_for("mac").await.expect("should be found");
        assert_eq!(host.protocol_version, 3);
        assert_eq!(host.name, "Studio");
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

        hosts.put("mac", "Studio".into(), 3, old_tx.clone()).await;
        hosts.put("mac", "Studio".into(), 3, new_tx.clone()).await;

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
    async fn asking_for_an_unknown_host_reports_it_offline() {
        let registry = Arc::new(Registry::new());
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
        let registry = Arc::new(Registry::new());
        let hosts = HostRegistry::new();
        let (host_tx, _host_rx) = channel();
        hosts.put("mac", "Studio".into(), 3, host_tx).await;

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
        let registry = Arc::new(Registry::new());
        let hosts = HostRegistry::new();
        let (host_tx, mut host_rx) = channel();
        hosts.put("mac", "Studio".into(), 3, host_tx).await;

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
        let registry = Arc::new(Registry::new());
        let hosts = HostRegistry::new();
        let (host_tx, _host_rx) = channel();
        hosts.put("mac", "Studio".into(), 3, host_tx).await;

        let quota = Arc::new(QuotaTracker::new(PlanAllowances::default(), Default::default()));
        // Recorded rather than configured away, so the test travels the same path a client does.
        quota.record("phone", Duration::from_secs(spent_seconds));
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

    /// Half an hour free means half an hour: a client that has spent more than that is refused.
    #[tokio::test]
    async fn a_spent_free_allowance_is_refused() {
        let reply = connect_with(None, 30 * 60 + 1).await;
        assert!(
            matches!(reply, Some(ServerMessage::Error { ref code, .. }) if code == "quotaExceeded"),
            "expected a quota refusal, got {reply:?}"
        );
    }

    /// The same client, saying `relay`, is inside its much larger allowance — which is the whole
    /// of what a subscription buys here.
    #[tokio::test]
    async fn a_relay_plan_is_still_connected_after_the_free_hour_is_spent() {
        let reply = connect_with(Some("relay"), 30 * 60 + 1).await;
        assert!(
            matches!(reply, Some(ServerMessage::SessionReady { .. })),
            "Relay should have three hours, not half an hour: {reply:?}"
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
}
