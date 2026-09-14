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

use std::collections::HashSet;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use tokio::net::UdpSocket;
use tokio::sync::oneshot;
use tokio::time::timeout;
use tracing::{debug, info};

use crate::config::PortRange;
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

/// Where a session's video port comes from.
enum PortChoice {
    /// No range configured, so let the OS pick. Fine on loopback, and fine anywhere the ports do
    /// not have to be named in a firewall rule.
    Any,
    Fixed(u16),
}

/// Hands out session video ports from a configured range, and takes them back when a session ends.
///
/// **The bookkeeping is ours rather than the operating system's**, and that is not belt-and-braces.
/// "Try to bind the next port and see whether it fails" is the obvious approach and it is wrong:
/// where `SO_REUSEADDR` is in play a bind succeeds against a port that is already in use, which
/// would put two sessions on one port and interleave two people's video. Tracking allocation here
/// is deterministic regardless of how the platform treats that flag.
pub struct PortPool {
    range: Option<PortRange>,
    used: Mutex<HashSet<u16>>,
}

impl PortPool {
    pub fn new(range: Option<PortRange>) -> Self {
        Self {
            range,
            used: Mutex::new(HashSet::new()),
        }
    }

    /// Whether a fixed range is in force. Used for the startup log, so an operator can see at a
    /// glance whether the ports they opened are the ports that will be used.
    pub fn range(&self) -> Option<PortRange> {
        self.range
    }

    fn take(&self) -> std::io::Result<PortChoice> {
        let Some(range) = self.range else {
            return Ok(PortChoice::Any);
        };

        let mut used = lock_ports(&self.used);
        match range.iter().find(|port| used.insert(*port)) {
            Some(port) => Ok(PortChoice::Fixed(port)),
            None => Err(std::io::Error::new(
                std::io::ErrorKind::AddrNotAvailable,
                format!(
                    "every port in the configured video range {}-{} is in use",
                    range.first, range.last
                ),
            )),
        }
    }

    fn release(&self, port: u16) {
        lock_ports(&self.used).remove(&port);
    }
}

fn lock_ports(ports: &Mutex<HashSet<u16>>) -> MutexGuard<'_, HashSet<u16>> {
    ports.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Binds a socket for one session and starts forwarding on it.
///
/// Returns the port the two ends should send to. The socket is bound before this returns, so a
/// client that is told the port can use it immediately.
pub async fn serve_session(
    bind: SocketAddr,
    pool: Arc<PortPool>,
    pairing: Arc<Mutex<VideoPairing>>,
    shutdown: oneshot::Receiver<()>,
    idle_ttl: Duration,
) -> std::io::Result<u16> {
    let mut addr = bind;
    let chosen = pool.take()?;
    let fixed = match chosen {
        PortChoice::Any => None,
        PortChoice::Fixed(port) => {
            addr.set_port(port);
            Some(port)
        }
    };

    let socket = match UdpSocket::bind(addr).await {
        Ok(socket) => socket,
        Err(error) => {
            // Hand the port straight back rather than leaving it marked as taken by a session that
            // never started — otherwise a port that cannot be bound at all is lost for the life of
            // the process, and a range full of them would exhaust itself.
            if let Some(port) = fixed {
                pool.release(port);
            }
            return Err(error);
        }
    };

    // Read from the socket rather than trusting `fixed`: with no range configured this is the OS's
    // choice, and it is the only place that value is known.
    let port = socket.local_addr()?.port();

    tokio::spawn(async move {
        forward(socket, pairing, shutdown, idle_ttl).await;
        if fixed.is_some() {
            pool.release(port);
        }
        debug!(port, "video session closed");
    });

    Ok(port)
}

async fn forward(
    socket: UdpSocket,
    pairing: Arc<Mutex<VideoPairing>>,
    mut shutdown: oneshot::Receiver<()>,
    idle_ttl: Duration,
) {
    let mut buf = vec![0u8; MAX_DATAGRAM];
    let mut dropped_unbound: u64 = 0;

    loop {
        // The shutdown arm breaks, so the receiver is never polled after it has resolved — which
        // matters, because polling a completed `oneshot` a second time panics.
        //
        // Waiting on this at all is what makes a one-port video range work. Otherwise the socket
        // lives out the idle timeout after a phone has already reconnected, and the replacement
        // session is refused the only port there is.
        let received = tokio::select! {
            _ = &mut shutdown => {
                debug!("session superseded; releasing the video port");
                break;
            }
            received = timeout(IDLE_POLL, socket.recv_from(&mut buf)) => received,
        };

        match received {
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

    /// Binds both ends, and returns the relay address, a socket for each end, and the session's
    /// keep-alive.
    ///
    /// The keep-alive is handed back rather than held here, and it has to be: it drives the
    /// shutdown signal, so dropping it on return would close the relay before the caller could use
    /// it. Every caller binds it for the length of the test.
    async fn connected_session() -> (SocketAddr, UdpSocket, UdpSocket, oneshot::Sender<()>) {
        let pairing = Arc::new(Mutex::new(VideoPairing::new([CLIENT_TOKEN, HOST_TOKEN])));
        let (keep_alive, shutdown) = oneshot::channel();

        let port = serve_session(
            ephemeral(),
            Arc::new(PortPool::new(None)),
            Arc::clone(&pairing),
            shutdown,
            Duration::from_secs(30),
        )
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

        (relay, client, host, keep_alive)
    }

    #[tokio::test]
    async fn a_datagram_reaches_the_other_end_and_not_back_to_its_sender() {
        let (relay, client, host, _session) = connected_session().await;

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
        // Held for the test's lifetime: dropping it would fire the shutdown signal immediately and
        // close the relay the test is about to use.
        let (_keep_alive, shutdown) = oneshot::channel();

        let port = serve_session(
            ephemeral(),
            Arc::new(PortPool::new(None)),
            Arc::clone(&pairing),
            shutdown,
            Duration::from_secs(30),
        )
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

    #[test]
    fn a_pool_without_a_range_lets_the_os_choose() {
        let pool = PortPool::new(None);
        assert!(matches!(pool.take(), Ok(PortChoice::Any)));
        assert!(pool.range().is_none());
    }

    #[test]
    fn a_pool_hands_out_each_port_once_and_then_refuses() {
        // Handing the same port to two sessions is the failure this bookkeeping exists to prevent,
        // and it is one the operating system would not necessarily catch — see the comment on
        // PortPool.
        let pool = PortPool::new(PortRange::parse("40000-40002"));

        let mut taken = Vec::new();
        for _ in 0..3 {
            match pool.take().expect("should still have a port") {
                PortChoice::Fixed(port) => taken.push(port),
                PortChoice::Any => panic!("a configured range should fix the port"),
            }
        }
        taken.sort();
        assert_eq!(taken, vec![40000, 40001, 40002], "each handed out exactly once");

        assert!(pool.take().is_err(), "an exhausted range must refuse");
    }

    #[test]
    fn a_released_port_becomes_available_again() {
        let pool = PortPool::new(PortRange::parse("40000-40000"));

        let Ok(PortChoice::Fixed(port)) = pool.take() else {
            panic!("the only port should be handed out");
        };
        assert!(pool.take().is_err(), "and then there are none left");

        pool.release(port);
        assert!(
            matches!(pool.take(), Ok(PortChoice::Fixed(again)) if again == port),
            "a session ending must give its port back, or a range exhausts itself over time"
        );
    }

    #[tokio::test]
    async fn a_session_binds_inside_the_configured_range() {
        // The property the firewall rule depends on: if it says these ports, these are the ports.
        let pool = Arc::new(PortPool::new(PortRange::parse("47800-47805")));
        let pairing = Arc::new(Mutex::new(VideoPairing::new([CLIENT_TOKEN, HOST_TOKEN])));
        let (_keep_alive, shutdown) = oneshot::channel();

        let port = serve_session(
            "127.0.0.1:0".parse().unwrap(),
            Arc::clone(&pool),
            pairing,
            shutdown,
            Duration::from_secs(30),
        )
        .await
        .expect("should bind inside the range");

        assert!(
            (47800..=47805).contains(&port),
            "bound {port}, which is outside the range the firewall would open"
        );
    }

    #[tokio::test]
    async fn a_superseded_session_gives_its_port_back_at_once() {
        // A range of exactly one, which is what a server with a single forwarded UDP port looks
        // like. Without the shutdown signal the first session would hold that port for the whole
        // idle timeout, so a phone reconnecting inside that window would be refused — and a phone
        // reconnects precisely when something has just gone wrong, which is the worst moment to
        // also be unable to start a session.
        let pool = Arc::new(PortPool::new(PortRange::parse("47900-47900")));
        let pairing = Arc::new(Mutex::new(VideoPairing::new([CLIENT_TOKEN, HOST_TOKEN])));

        let (first_keep_alive, first_shutdown) = oneshot::channel();
        let first = serve_session(
            ephemeral(),
            Arc::clone(&pool),
            Arc::clone(&pairing),
            first_shutdown,
            Duration::from_secs(300),
        )
        .await
        .expect("the first session should get the only port");
        assert_eq!(first, 47900);

        // A second session while the first is still live is genuinely refused — there is one port
        // and it is taken. This is the correct answer, not a bug.
        let (_second_keep_alive, second_shutdown) = oneshot::channel();
        assert!(
            serve_session(
                ephemeral(),
                Arc::clone(&pool),
                Arc::clone(&pairing),
                second_shutdown,
                Duration::from_secs(300),
            )
            .await
            .is_err(),
            "a second session cannot have the port while the first holds it"
        );

        // Dropping the sender is what the registry does when a reconnect supersedes a session.
        drop(first_keep_alive);

        // The task has to wake and release, which is asynchronous — poll rather than sleeping a
        // fixed amount, so the test does not encode a guess about scheduling.
        let mut second_keep_alive = None;
        let mut reclaimed = None;
        for _ in 0..50 {
            tokio::time::sleep(Duration::from_millis(20)).await;
            let (keep_alive, shutdown) = oneshot::channel();
            if let Ok(port) = serve_session(
                ephemeral(),
                Arc::clone(&pool),
                Arc::clone(&pairing),
                shutdown,
                Duration::from_secs(300),
            )
            .await
            {
                second_keep_alive = Some(keep_alive);
                reclaimed = Some(port);
                break;
            }
        }

        assert_eq!(
            reclaimed,
            Some(47900),
            "the port must come back as soon as the old session is superseded, not when it expires"
        );
        drop(second_keep_alive);
    }
}
