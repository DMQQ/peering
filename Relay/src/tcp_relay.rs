//! The control relay: two connections in, one pipe out.
//!
//! This is deliberately the least clever code in the project. It reads a token, finds the session,
//! waits for the other half, and copies bytes until one side stops. It cannot read what it copies,
//! because what it copies is a TLS session belonging to the two ends — see `TLSConfig` and the
//! pinning in `PeerPinning.swift` on the Swift side, which is where the actual authorization
//! happens.
//!
//! The token arrives in the clear, before TLS starts. That is not an oversight: the token is what
//! tells us where the TLS handshake should be carried, so it necessarily precedes it. See the
//! module comment on `session.rs` for why that is safe.

use std::sync::Arc;
use std::time::Duration;

use tokio::io::AsyncReadExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::time::timeout;
use tracing::{debug, info, warn};

use crate::session::{Join, Registry, Token};

/// How long a connection may sit without presenting a token. Long enough to survive a slow start,
/// short enough that an idle socket cannot be used to hold resources.
const TOKEN_DEADLINE: Duration = Duration::from_secs(5);

pub async fn serve(listener: TcpListener, registry: Arc<Registry>) {
    info!(addr = %listener.local_addr().map(|a| a.to_string()).unwrap_or_default(), "control relay listening");

    loop {
        match listener.accept().await {
            Ok((stream, peer)) => {
                // Nagle off, on both halves of every splice. This one listener accepts *both*
                // ends of a session — the connection that waits and the one handed to it — so
                // setting it here covers the pair, and `copy_bidirectional` below inherits it.
                //
                // This is not a tuning preference. What crosses here is a coalesced 60 Hz
                // command stream in small writes, and Nagle holds a partial segment until the
                // previous one is acknowledged. On a path whose RTT is tens of milliseconds
                // that is a round trip added to every cursor position, which is the class of
                // delay the user feels most directly. It cannot be fixed above us either: the
                // buffering happens below the copy, in the kernel.
                //
                // A failure here costs latency, not correctness, so it is logged and carried
                // on rather than closing a connection that would otherwise work.
                if let Err(error) = stream.set_nodelay(true) {
                    warn!(%error, %peer, "could not disable Nagle on a control connection");
                }

                let registry = Arc::clone(&registry);
                tokio::spawn(async move {
                    if let Err(error) = handle(stream, registry).await {
                        debug!(%peer, %error, "control connection ended");
                    }
                });
            }
            // A failed accept is about this connection, not the listener — a file-descriptor
            // exhaustion or a peer that vanished mid-handshake. Logging and carrying on is right;
            // tearing the listener down would take every other session with it.
            Err(error) => warn!(%error, "control listener could not accept"),
        }
    }
}

async fn handle(mut stream: TcpStream, registry: Arc<Registry>) -> std::io::Result<()> {
    // No buffering here, and none needed: this is the only read this side ever does. Everything
    // after it belongs to TLS.
    let mut token: Token = [0u8; 16];
    timeout(TOKEN_DEADLINE, stream.read_exact(&mut token))
        .await
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::TimedOut, "no token presented"))??;

    let Some(join) = registry.join_control(&token, stream).await else {
        // Not a token we issued, or one that has already been used or swept. Closed without a
        // reply, so a probe learns nothing about whether the session exists.
        return Ok(());
    };

    let Join::Waiting { mut mine, peer } = join else {
        debug!("control connection handed to its peer");
        return Ok(());
    };

    // Waiting for the peer is deliberately unbounded. The bound that matters is the session's own
    // lifetime: when the sweep takes an abandoned session it drops the sender, this await fails,
    // and the socket closes. A second timeout here would only duplicate that with a second number
    // to keep in step.
    let Ok(mut theirs) = peer.await else {
        debug!("session was swept before the peer connected");
        return Ok(());
    };

    debug!(peer = %theirs.peer_addr().map(|a| a.to_string()).unwrap_or_default(), "splicing");

    // Copies both directions until either side closes. The result is discarded on purpose: a
    // session ending is the normal case, not an error worth logging at a level anyone reads.
    let _ = tokio::io::copy_bidirectional(&mut mine, &mut theirs).await;

    // Released so the token cannot be presented again. Without this a token stays valid for the
    // rest of its TTL, and a leaked one could hold a splice open.
    registry.release(&token).await;
    debug!("splice finished");
    Ok(())
}
