//! Accepting signalling sockets and running each one's message loop.

use std::net::IpAddr;
use std::sync::Arc;
use std::time::Duration;

use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio::time;
use tracing::{debug, info, warn};

use super::connection::handle;
use super::{HostRegistry, Settings};
use crate::limits::{PeerLimiter, Permit};
use crate::session::Registry;
use crate::stats::{Refusal, TALLY};

/// Accepts signalling connections. `tls` wraps each socket before the WebSocket handshake; without
/// it the channel is plaintext, which is only appropriate on loopback.
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

    // A socket that arrives with every permit taken is closed, not queued: queuing turns a flood
    // into a backlog, and the clients that matter retry. Clamped because `Semaphore::new` panics
    // above its own maximum.
    let permits = Arc::new(Semaphore::new(settings.max_connections.min(Semaphore::MAX_PERMITS)));
    let shared = Shared { registry, hosts, settings, tls };
    let settings = &shared.settings;

    loop {
        let (stream, peer_address) = match listener.accept().await {
            Ok(pair) => pair,
            Err(error) => {
                warn!(%error, "signalling listener could not accept");
                time::sleep(Duration::from_millis(50)).await;
                continue;
            }
        };
        let Ok(permit) = Arc::clone(&permits).try_acquire_owned() else {
            warn!("refused a signalling connection: the listener is at its limit");
            continue;
        };
        let peer = Some(peer_address.ip());
        let Some(ip_permit) = admit_peer(&settings.limiter, peer) else {
            TALLY.refused(Refusal::PerIpLimit);
            debug!("refused a signalling connection: this address is at its limit");
            continue;
        };

        let relay_host = relay_host_for(settings, &stream);
        shared.spawn(stream, peer, relay_host, (permit, ip_permit));
    }
}

/// What every accepted connection is handed.
struct Shared {
    registry: Arc<Registry>,
    hosts: HostRegistry,
    settings: Settings,
    tls: Option<tokio_rustls::TlsAcceptor>,
}

impl Shared {
    fn spawn(
        &self,
        stream: TcpStream,
        peer: Option<IpAddr>,
        relay_host: String,
        permits: (OwnedSemaphorePermit, Option<Permit>),
    ) {
        let (registry, hosts, settings) = (Arc::clone(&self.registry), self.hosts.clone(), self.settings.clone());
        let tls = self.tls.clone();
        tokio::spawn(async move {
            match tls {
                Some(acceptor) => {
                    // A socket that opens TLS and never finishes it would hold its permit for ever.
                    // The arms that only log are braced: a tracing macro's temporary lives to the end
                    // of the match, and another arm awaits, so the future would stop being `Send`.
                    match time::timeout(settings.handshake_timeout, acceptor.accept(stream)).await {
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
                }
                None => handle(stream, peer, relay_host, registry, hosts, settings).await,
            }
            drop(permits);
        });
    }
}

/// The address this client reached us on is the one it can reach us on again, so it is read from
/// the accepted socket rather than from configuration.
fn relay_host_for(settings: &Settings, stream: &TcpStream) -> String {
    match (&settings.host, stream.local_addr()) {
        (Some(configured), _) => configured.clone(),
        (None, Ok(local)) => local.ip().to_string(),
        (None, Err(_)) => "127.0.0.1".to_string(),
    }
}

/// `Some(None)` is an address with no accounting, which is every address when `peer` is unknown.
fn admit_peer(limiter: &Arc<PeerLimiter>, peer: Option<IpAddr>) -> Option<Option<Permit>> {
    match peer {
        Some(ip) => limiter.admit_signalling(ip).map(Some),
        None => Some(None),
    }
}
