//! The video relay: one UDP socket per session, forwarding between the two ends that bound to it.
//!
//! Per-session sockets rather than one shared socket with a demultiplexing header, and the reason
//! is the payload: what crosses here is sealed video, and a header of ours sitting in front of it
//! would have to be parsed, validated and re-emitted for every datagram at video rates. A port
//! that is already unique to a session answers the same question once, at allocation, for free.
//!
//! The datagrams are opaque. The two ends seal them with a key the relay is never told — see the
//! session-key exchange in the plan — so a relay that wanted to look at the screen would find
//! ciphertext, and one that wanted to tamper with it would be caught by the tag.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use tokio::net::UdpSocket;
use tokio::time::timeout;
use tracing::{debug, info};

use crate::session::{Token, VideoPairing};

/// Marks a datagram as "this is where I live" rather than payload.
const BIND_MAGIC: [u8; 4] = *b"PBND";
pub const BIND_LEN: usize = 4 + 16;

/// How often an idle session re-checks whether it is still wanted.
const IDLE_POLL: Duration = Duration::from_secs(10);

/// The largest datagram we will carry. Deliberately the protocol maximum rather than something
/// snug: `recv_from` **truncates** into a short buffer, and a truncated datagram would be
/// forwarded as a smaller but perfectly well-formed packet, which is far worse than dropping it.
/// Clients keep under the path MTU, so this is never reached in practice.
const MAX_DATAGRAM: usize = 65_535;

/// The bind packet a client sends to claim its slot. Also what the Swift side must produce.
pub fn bind_packet(token: &Token) -> Vec<u8> {
    let mut packet = Vec::with_capacity(BIND_LEN);
    packet.extend_from_slice(&BIND_MAGIC);
    packet.extend_from_slice(token);
    packet
}

/// The token a bind packet carries, if this is a bind packet at all.
///
/// Only the shape is checked here; whether the token belongs to *this* session is
/// [`VideoPairing::bind`]'s question, because answering it is what decides the slot.
fn bind_token(packet: &[u8]) -> Option<Token> {
    if packet.len() != BIND_LEN || packet[..4] != BIND_MAGIC {
        return None;
    }
    let mut token = [0u8; 16];
    token.copy_from_slice(&packet[4..]);
    Some(token)
}

/// Binds a socket for one session and starts forwarding on it.
///
/// Returns the port the two ends should send to. The socket is bound before this returns, so a
/// client that is told the port can use it immediately.
pub async fn serve_session(
    bind: SocketAddr,
    pairing: Arc<Mutex<VideoPairing>>,
    idle_ttl: Duration,
) -> std::io::Result<u16> {
    let socket = UdpSocket::bind(bind).await?;
    let port = socket.local_addr()?.port();

    tokio::spawn(async move {
        forward(socket, pairing, idle_ttl).await;
        debug!("video session closed");
    });

    Ok(port)
}

async fn forward(socket: UdpSocket, pairing: Arc<Mutex<VideoPairing>>, idle_ttl: Duration) {
    let mut buf = vec![0u8; MAX_DATAGRAM];
    let mut dropped_unbound: u64 = 0;

    loop {
        match timeout(IDLE_POLL, socket.recv_from(&mut buf)).await {
            Ok(Ok((len, from))) => {
                let packet = &buf[..len];

                // A bind packet carrying a token from this session claims or moves a slot. One
                // carrying anything else falls through rather than being swallowed here, so a
                // stray packet cannot consume the bind path — it is then dropped as unbound
                // traffic, which is the correct outcome for a token that is not ours.
                if let Some(claimed) = bind_token(packet)
                    && let Some(slot) = lock(&pairing).bind(&claimed, from)
                {
                    debug!(%from, slot, "video slot bound");
                    continue;
                }

                // Bound to a name *before* the match, and that is load-bearing rather than
                // stylistic. A temporary in a `match` scrutinee lives until the end of the match,
                // so `match lock(..).peer_of(..)` would hold the guard across the `send_to` await
                // below — serialising every datagram of the session behind one lock and making
                // this future non-`Send`. As a separate statement the guard is released at the
                // semicolon.
                let peer = lock(&pairing).peer_of(&from);
                match peer {
                    Some(peer) => {
                        let _ = socket.send_to(packet, peer).await;
                    }
                    // An unbound source gets no reply, for the same reason an unknown control
                    // token gets none: silence tells a prober nothing about whether a session is
                    // here. Counted rather than logged per packet, because a stray scanner or a
                    // client that bound to the wrong port would otherwise write a line per
                    // datagram and bury everything else.
                    None => dropped_unbound += 1,
                }
            }
            Ok(Err(error)) => {
                debug!(%error, "video socket failed");
                break;
            }
            // Nothing arrived. That is the moment to ask whether the session is still wanted at
            // all — a client that walked away leaves a socket bound until something notices, and
            // this is what notices.
            Err(_) => {
                if lock(&pairing).idle_for() > idle_ttl {
                    if dropped_unbound > 0 {
                        info!(dropped_unbound, "video session expired with unbound traffic");
                    }
                    break;
                }
            }
        }
    }
}

/// A poisoned lock only means some other task panicked while holding it, and the data here — two
/// socket addresses — cannot be left inconsistent by a panic. Recovering beats taking the whole
/// relay down over a session's bookkeeping.
fn lock(pairing: &Mutex<VideoPairing>) -> MutexGuard<'_, VideoPairing> {
    pairing.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    const CLIENT_TOKEN: Token = [3u8; 16];
    const HOST_TOKEN: Token = [4u8; 16];

    fn local(port: u16) -> SocketAddr {
        SocketAddr::from((Ipv4Addr::LOCALHOST, port))
    }

    fn ephemeral() -> SocketAddr {
        local(0)
    }

    #[test]
    fn a_bind_packet_yields_the_token_it_carries() {
        let token = [7u8; 16];
        assert_eq!(bind_token(&bind_packet(&token)), Some(token));

        assert_eq!(bind_token(&[]), None);
        assert_eq!(bind_token(&bind_packet(&token)[..8]), None, "truncated");
        assert_eq!(bind_token(b"not a bind packet at all"), None);
    }

    #[test]
    fn a_payload_shaped_like_a_bind_packet_cannot_claim_a_slot() {
        // Video datagrams are opaque and arbitrary bytes, so one that happens to begin with the
        // magic and be exactly the right length must not be able to take a slot. What stops it is
        // that the token is checked against the session rather than merely parsed — which is why
        // that check lives in the pairing and not here.
        let mut video = VideoPairing::new([CLIENT_TOKEN, HOST_TOKEN]);
        let impostor = bind_token(&bind_packet(&[8u8; 16])).expect("the shape is right");
        assert_ne!(impostor, CLIENT_TOKEN);

        assert_eq!(video.bind(&impostor, local(5000)), None);
        assert_eq!(video.peer_of(&local(5000)), None);
    }

    /// Binds both ends and returns the relay address, a socket for each end, and the pairing.
    async fn connected_session() -> (SocketAddr, UdpSocket, UdpSocket) {
        let pairing = Arc::new(Mutex::new(VideoPairing::new([CLIENT_TOKEN, HOST_TOKEN])));
        let port = serve_session(ephemeral(), Arc::clone(&pairing), Duration::from_secs(30))
            .await
            .expect("should bind");

        let relay = local(port);
        let client = UdpSocket::bind(ephemeral()).await.unwrap();
        let host = UdpSocket::bind(ephemeral()).await.unwrap();

        // Both ends claim a slot before any payload moves, which is what the real clients do on
        // connecting and what stops the first datagram from being dropped as unbound.
        client.send_to(&bind_packet(&CLIENT_TOKEN), relay).await.unwrap();
        host.send_to(&bind_packet(&HOST_TOKEN), relay).await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;

        (relay, client, host)
    }

    #[tokio::test]
    async fn a_datagram_reaches_the_other_end_and_not_back_to_its_sender() {
        let (relay, client, host) = connected_session().await;

        client.send_to(b"from the phone", relay).await.unwrap();

        let mut buf = [0u8; 64];
        let (len, _) = timeout(Duration::from_secs(2), host.recv_from(&mut buf))
            .await
            .expect("the peer should receive it within the timeout")
            .unwrap();
        assert_eq!(&buf[..len], b"from the phone");

        // And not echoed back: a relay that reflected traffic to its sender would double every
        // frame and make the stream incomprehensible at the far end.
        assert!(
            timeout(Duration::from_millis(200), client.recv_from(&mut buf))
                .await
                .is_err(),
            "the sender should not receive its own datagram back"
        );
    }

    #[tokio::test]
    async fn traffic_from_an_unbound_address_is_dropped_without_a_reply() {
        let pairing = Arc::new(Mutex::new(VideoPairing::new([CLIENT_TOKEN, HOST_TOKEN])));
        let port = serve_session(ephemeral(), Arc::clone(&pairing), Duration::from_secs(30))
            .await
            .expect("should bind");

        let stranger = UdpSocket::bind(ephemeral()).await.unwrap();
        stranger.send_to(b"hello?", local(port)).await.unwrap();

        let mut buf = [0u8; 64];
        assert!(
            timeout(Duration::from_millis(200), stranger.recv_from(&mut buf))
                .await
                .is_err(),
            "an unbound source should be ignored, not answered"
        );
    }
}
