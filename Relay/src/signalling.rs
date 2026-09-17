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

use crate::protocol::{hex, ClientMessage, ServerMessage};
use crate::session::{CLIENT_SLOT, HOST_SLOT, Registry, Token};
use crate::udp_relay;

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
    pub video_bind: SocketAddr,
    /// Where session video ports come from — see [`udp_relay::PortPool`].
    pub video_ports: Arc<udp_relay::PortPool>,
    /// The video port as clients reach it, for the same reason as `public_control_port`. Only
    /// meaningful with a single-port range: with several, each session gets its own port and there
    /// is no per-session mapping to express.
    pub public_video_port: Option<u16>,
    pub session_ttl: Duration,
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
    // 64 KB is large enough for the biggest valid message (a SessionReady with two 32-char hex
    // tokens plus a hostname) by a generous margin, and small enough to close a connection sending
    // garbage before it allocates a meaningful amount of memory.
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
    let mut registered_as: Option<String> = None;

    loop {
        tokio::select! {
            incoming = source.next() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        let reply = match serde_json::from_str::<ClientMessage>(&text) {
                            Ok(message) => {
                                dispatch(message, &tx, &registry, &hosts, &settings, &relay_host, &mut registered_as).await
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

    if let Some(device_id) = registered_as {
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
    registered_as: &mut Option<String>,
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
            *registered_as = Some(device_id.clone());
            info!(%device_id, %name, protocol_version, "host registered");
            Some(ServerMessage::Registered {
                session_ttl_seconds: settings.session_ttl.as_secs(),
            })
        }

        ClientMessage::ConnectToHost {
            host_id,
            client_id,
            protocol_version,
        } => {
            if host_id.len() > MAX_FIELD || client_id.len() > MAX_FIELD {
                return Some(ServerMessage::error("invalid", "field too long"));
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

            let allocated = registry.allocate(&host_id, &client_id).await;

            let video_port = match udp_relay::serve_session(
                settings.video_bind,
                Arc::clone(&settings.video_ports),
                Arc::clone(&allocated.video),
                allocated.shutdown,
                settings.session_ttl,
            )
            .await
            {
                Ok(port) => port,
                Err(error) => {
                    warn!(%error, "could not bind a video socket");
                    return Some(ServerMessage::error("relay", "no video port available"));
                }
            };

            // The name is here because it is the one thing that makes this log line useful to
            // whoever is running the relay: a device ID identifies a machine to a database, and a
            // name identifies it to a person reading `journalctl`.
            info!(%host_id, host_name = %host.name, %client_id, video_port, "session allocated");

            // The two ends get *different* video tokens, which is the one place the messages they
            // receive diverge. See `VideoPairing` for why a shared token cannot express a re-bind.
            // The control token is shared because it is presented once by each side and used up.
            let ready = |video_token: Token| ServerMessage::SessionReady {
                control_host: relay_host.to_string(),
                control_port: settings.public_control_port,
                video_host: relay_host.to_string(),
                // The bound port unless it has been said otherwise, which is the case on a shared
                // address where the forwarded port is the host's to choose.
                video_port: settings.public_video_port.unwrap_or(video_port),
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

        ClientMessage::Ping => Some(ServerMessage::Pong),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn channel() -> (mpsc::Sender<ServerMessage>, mpsc::Receiver<ServerMessage>) {
        mpsc::channel(4)
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
        let settings = Settings {
            host: None,
            public_control_port: 9443,
            video_bind: "127.0.0.1:0".parse().unwrap(),
            video_ports: Arc::new(udp_relay::PortPool::new(None)),
            public_video_port: None,
            session_ttl: Duration::from_secs(60),
        };
        let (tx, _rx) = channel();
        let mut registered = None;

        let reply = dispatch(
            ClientMessage::ConnectToHost {
                host_id: "ghost".into(),
                client_id: "phone".into(),
                protocol_version: 3,
            },
            &tx,
            &registry,
            &hosts,
            &settings,
            "127.0.0.1",
            &mut registered,
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

        let settings = Settings {
            host: None,
            public_control_port: 9443,
            video_bind: "127.0.0.1:0".parse().unwrap(),
            video_ports: Arc::new(udp_relay::PortPool::new(None)),
            public_video_port: None,
            session_ttl: Duration::from_secs(60),
        };
        let (tx, _rx) = channel();
        let mut registered = None;

        let reply = dispatch(
            ClientMessage::ConnectToHost {
                host_id: "mac".into(),
                client_id: "phone".into(),
                protocol_version: 2,
            },
            &tx,
            &registry,
            &hosts,
            &settings,
            "127.0.0.1",
            &mut registered,
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

        let settings = Settings {
            host: None,
            public_control_port: 9443,
            video_bind: "127.0.0.1:0".parse().unwrap(),
            video_ports: Arc::new(udp_relay::PortPool::new(None)),
            public_video_port: None,
            session_ttl: Duration::from_secs(60),
        };
        let (tx, _rx) = channel();
        let mut registered = None;

        let reply = dispatch(
            ClientMessage::ConnectToHost {
                host_id: "mac".into(),
                client_id: "phone".into(),
                protocol_version: 3,
            },
            &tx,
            &registry,
            &hosts,
            &settings,
            "relay.test",
            &mut registered,
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
        assert_ne!(ready.3, 0, "a real video port should have been bound");

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
}
