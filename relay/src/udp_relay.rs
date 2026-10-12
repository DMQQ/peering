//! The video relay: one UDP socket for the whole relay, demultiplexed by the token each datagram
//! starts with.
//!
//! # Why one socket
//!
//! The previous design bound a socket per session, out of a configured range of ports, and gave the
//! port to both ends in their `ready` message. The argument for it was that a port unique to a
//! session answers "whose datagram is this" once, at allocation, for free — no header to parse, no
//! table to keep. What that argument did not price is the port itself. The production host forwards
//! a handful of ports on a shared IPv4, its video range is a single port, and a range of one is a
//! ceiling of one session with video. The cost of a per-session port is a port per session, and
//! there is nowhere to get more of them.
//!
//! So every session now sends to the same address, and the first sixteen bytes of every datagram
//! say which session and which end it came from. That prefix is not a new field and needs no round
//! trip to establish: it is the end's own video token, the same one its `ready` message already
//! carried, and the relay looks it up in the routing table (`session::VideoRoutes`) and forwards
//! what follows to the other end. One forwarded port, any number of sessions.
//!
//! # What the relay may read
//!
//! The prefix, and only because it has to route on it. Behind it sits the counter the two ends use
//! to order frames, eight bytes that this process can see and must not care about, and then the
//! sealed frame, which it can neither read nor forge: the ends seal those with a key the relay was
//! never told, so everything past the prefix is ciphertext and the tag that would catch a tamperer
//! is not ours to check. `lib.rs` states that as the design principle, and this is where it has to
//! stay true — a relay with a shared port has more reasons to look inside a datagram, not fewer.
//!
//! One consequence is worth writing down rather than discovering later: a video token now travels
//! in the clear in front of every datagram, on a port anyone can reach, so anyone on the path can
//! read one. The bind packet this replaced put the token on the wire in the clear too — this is the
//! same bargain, not a new one — but it is now in every datagram rather than in the occasional one,
//! and a port that serves every session is a port worth probing. What a token buys is a claim on a
//! slot: a redirect, or a way to stop one end's video, at worst. Not a frame of it, which is sealed
//! with a key this process never sees — see the module comment on `session`.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use tokio::net::UdpSocket;
use tokio::time::MissedTickBehavior;
use tracing::{debug, info, warn};

use crate::session::{Routed, Token, VideoRoutes};
use crate::stats::TALLY;

/// The token that opens every datagram: the one part of it this process reads, and the only part it
/// is entitled to. Fixed by the wire contract, and the length of a [`Token`].
pub const PREFIX_LEN: usize = 16;

/// How often the shared socket looks for sessions that have gone quiet.
///
/// Ten seconds against a session TTL measured in minutes: soon enough that an abandoned session is
/// not routed for long, rare enough that the scan is nothing.
const REAP_INTERVAL: Duration = Duration::from_secs(10);

/// The largest datagram we will carry. Deliberately the protocol maximum rather than something
/// snug: `recv_from` **truncates** into a short buffer, and a truncated datagram would be forwarded
/// as a smaller but perfectly well-formed packet, which is far worse than dropping it. Clients keep
/// under the path MTU, so this is never reached in practice.
const MAX_DATAGRAM: usize = 65_535;

/// How long the receive loop waits after a failed read before trying again.
const RECEIVE_BACKOFF: Duration = Duration::from_millis(10);

/// Binds the relay's one video socket and starts forwarding on it.
///
/// Bound once, before any session exists, and the address is what every `ready` message names: the
/// port is a property of the relay now, not of a session, so it is decided here and never again.
/// Port 0 asks the OS to choose, which is what a relay with no firewall in front of it wants and
/// what the tests use; an explicit port is what a forwarded one needs, and it is the only number an
/// operator has to open.
///
/// Returns the address actually bound, so a caller configured with port 0 can report the port it
/// was given — this is the only place that number is known.
pub async fn serve(
    bind: SocketAddr,
    routes: Arc<VideoRoutes>,
    idle_ttl: Duration,
) -> std::io::Result<SocketAddr> {
    let socket = UdpSocket::bind(bind).await?;
    let bound = socket.local_addr()?;

    tokio::spawn(forward(socket, routes, idle_ttl));

    Ok(bound)
}

async fn forward(socket: UdpSocket, routes: Arc<VideoRoutes>, idle_ttl: Duration) {
    let mut buf = vec![0u8; MAX_DATAGRAM];
    let mut dropped: u64 = 0;

    // Expiry has a clock of its own rather than riding on the socket falling silent. The old
    // per-session socket was read by nobody but its own session, so silence meant *that* session
    // had stopped; this one carries every session, so it is silent only when all of them are, and a
    // session that went quiet while another kept streaming would never be looked at at all.
    let mut reap = tokio::time::interval(REAP_INTERVAL);
    // Delay rather than the default burst: a reactor that was busy for a while should not come back
    // and run a handful of expiry passes back to back.
    reap.set_missed_tick_behavior(MissedTickBehavior::Delay);

    loop {
        tokio::select! {
            _ = reap.tick() => {
                let expired = routes.reap(idle_ttl);
                if expired > 0 {
                    // The dropped count is reported beside it because the two answer one question,
                    // which is how much arrives that no live session claims. At most one line per
                    // tick, never one per datagram: at video rates a line per drop would bury the
                    // log it is written to.
                    info!(expired, dropped, "expired video sessions");
                } else if dropped > 0 {
                    debug!(dropped, "video datagrams arrived that no bound session claims");
                }
                dropped = 0;
            }

            received = socket.recv_from(&mut buf) => match received {
                Ok((len, from)) => {
                    let packet = &buf[..len];

                    // Shorter than a token, so it names nothing and cannot be routed. This is the
                    // only length rule here, and it is about routing rather than about the payload:
                    // everything past the prefix belongs to the two ends and is never inspected,
                    // counted or validated, whatever it looks like.
                    if packet.len() < PREFIX_LEN {
                        dropped += 1;
                        TALLY.udp_unclaimed();
                        continue;
                    }

                    // Infallible: the slice is exactly `PREFIX_LEN`, which is the length of a
                    // token. Worth the `expect` rather than a copy of the first line of every
                    // datagram.
                    let token: &Token = packet[..PREFIX_LEN]
                        .try_into()
                        .expect("a prefix is exactly the length of a token");

                    match routes.route_sized(token, from, packet.len() - PREFIX_LEN) {
                        // No session holds this token, or the address it came from already holds
                        // the other end of the session it claims. Dropped without a reply, for the
                        // same reason an unknown control token gets none: silence tells a prober
                        // nothing about whether a session is here, and the honest answer to both
                        // cases is that there is no route.
                        Routed::Dropped => {
                            dropped += 1;
                            TALLY.udp_unclaimed();
                        }

                        // Bound, but the other end has not claimed its slot yet, so there is
                        // nowhere to send this. Early rather than wrong: the frames a Mac sends
                        // before its phone has spoken are dropped here, and the ones after it
                        // speaks are not.
                        Routed::NoPeer => {}

                        // A datagram that is nothing but the prefix. It binds the address it came
                        // from and asks for nothing back: it is how an end claims its slot, and how
                        // it keeps a NAT mapping from expiring under a session. There is nothing to
                        // forward — a bare token is not a frame, and passing it on would hand the
                        // peer an empty datagram to reject.
                        Routed::Peer(_) if packet.len() == PREFIX_LEN => {}

                        // Everything past the prefix, forwarded exactly as it arrived. The relay
                        // does not parse it, cannot read it, and must not rewrite it: its shape is
                        // the two ends' business, and a datagram that is not a whole number of
                        // anything is still a datagram they may have meant.
                        Routed::Peer(peer) => {
                            let _ = socket.send_to(&packet[PREFIX_LEN..], peer).await;
                        }
                    }
                }
                // One datagram failed, which is a thing that happens: a queue overrun, or an error
                // the kernel is reporting from an earlier send on this socket. None of them mean
                // the port is unusable, and breaking here would take every session's video down at
                // once over something that cost one datagram. The pause is what stops an error the
                // kernel keeps repeating from turning this loop into a spin; it is not on the path
                // a working relay takes.
                Err(error) => {
                    warn!(%error, "video socket failed to receive");
                    tokio::time::sleep(RECEIVE_BACKOFF).await;
                }
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::{CLIENT_SLOT, HOST_SLOT};
    use std::net::Ipv4Addr;

    const CLIENT_TOKEN: Token = [3u8; 16];
    const HOST_TOKEN: Token = [4u8; 16];

    fn local(port: u16) -> SocketAddr {
        SocketAddr::from((Ipv4Addr::LOCALHOST, port))
    }

    fn ephemeral() -> SocketAddr {
        local(0)
    }

    /// A relay with one socket and an empty table, and the table so a test can open sessions in it.
    async fn relay() -> (SocketAddr, Arc<VideoRoutes>) {
        let routes = Arc::new(VideoRoutes::new());
        let addr = serve(
            ephemeral(),
            Arc::clone(&routes),
            Duration::from_secs(300),
        )
        .await
        .expect("should bind");
        (addr, routes)
    }

    /// A datagram as an end produces one: its own token, then whatever it wants forwarded.
    fn datagram(token: &Token, payload: &[u8]) -> Vec<u8> {
        let mut packet = token.to_vec();
        packet.extend_from_slice(payload);
        packet
    }

    /// Both ends bound, with one socket for each: exactly what two clients do on connecting.
    async fn bound_session(
        relay: SocketAddr,
        routes: &VideoRoutes,
        tokens: &[Token; 2],
    ) -> (UdpSocket, UdpSocket) {
        routes.open(tokens);
        let client = UdpSocket::bind(ephemeral()).await.unwrap();
        let host = UdpSocket::bind(ephemeral()).await.unwrap();

        // A bare token each, which is all a bind is now. Nothing payload-shaped moves before the
        // slots are bound, so a test that follows is testing the forwarding and not the bind.
        client.send_to(&tokens[CLIENT_SLOT], relay).await.unwrap();
        host.send_to(&tokens[HOST_SLOT], relay).await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;

        (client, host)
    }

    /// What the other end received, or `None` if nothing arrived in time.
    ///
    /// The buffer is the protocol maximum for the same reason the relay's is: a test that truncated
    /// would report the relay as having changed a datagram it forwarded perfectly.
    async fn received(socket: &UdpSocket) -> Option<Vec<u8>> {
        let mut buf = [0u8; 65_535];
        let (len, _) = tokio::time::timeout(Duration::from_millis(200), socket.recv_from(&mut buf))
            .await
            .ok()?
            .ok()?;
        Some(buf[..len].to_vec())
    }

    #[tokio::test]
    async fn a_datagram_reaches_the_other_end_without_its_prefix() {
        let (relay, routes) = relay().await;
        let (client, host) =
            bound_session(relay, &routes, &[CLIENT_TOKEN, HOST_TOKEN]).await;

        // What a client sends: its token, the counter, the sealed frame and its tag. Only the last
        // three are anybody else's business.
        let sealed = b"\x00\x00\x00\x00\x00\x00\x00\x07the sealed frame\x00\x00tag";
        client
            .send_to(&datagram(&CLIENT_TOKEN, sealed), relay)
            .await
            .unwrap();

        let forwarded = received(&host).await.expect("the peer should receive it");
        assert_eq!(
            forwarded, sealed,
            "the peer gets the datagram less the prefix, byte for byte"
        );
        assert!(
            !forwarded.starts_with(&CLIENT_TOKEN),
            "and specifically not the sender's token left in front of it"
        );

        // Not echoed back either: a relay that reflected traffic to its sender would double every
        // frame and make the stream incomprehensible at the far end.
        assert!(
            received(&client).await.is_none(),
            "the sender should not receive its own datagram back"
        );
    }

    #[tokio::test]
    async fn a_bare_token_binds_and_forwards_nothing() {
        let (relay, routes) = relay().await;
        routes.open(&[CLIENT_TOKEN, HOST_TOKEN]);
        let client = UdpSocket::bind(ephemeral()).await.unwrap();
        let host = UdpSocket::bind(ephemeral()).await.unwrap();
        // The host binds first so that the only thing missing is the client's slot: if the bare
        // token were forwarded, or if it failed to bind, this test would say which.
        host.send_to(&HOST_TOKEN, relay).await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;

        client.send_to(&CLIENT_TOKEN, relay).await.unwrap();
        assert!(
            received(&host).await.is_none(),
            "a datagram of nothing but a token carries nothing to forward"
        );

        // And it did bind: a frame the client sends next arrives at the host, which can only happen
        // if the client's slot was claimed by the bare token before it.
        client
            .send_to(&datagram(&CLIENT_TOKEN, b"a frame"), relay)
            .await
            .unwrap();
        assert_eq!(received(&host).await.as_deref(), Some(&b"a frame"[..]));
    }

    #[tokio::test]
    async fn a_repeated_bare_token_is_accepted_and_still_forwards_nothing() {
        // The keepalive. A client re-sends its token on a timer for the life of the session, so
        // this is the most common datagram on the socket by a wide margin, and it must be quiet:
        // not an error, not a log line, and above all not something the peer is handed.
        let (relay, routes) = relay().await;
        let (client, host) =
            bound_session(relay, &routes, &[CLIENT_TOKEN, HOST_TOKEN]).await;

        for _ in 0..3 {
            client.send_to(&CLIENT_TOKEN, relay).await.unwrap();
        }
        assert!(received(&host).await.is_none());

        client
            .send_to(&datagram(&CLIENT_TOKEN, b"still here"), relay)
            .await
            .unwrap();
        assert_eq!(received(&host).await.as_deref(), Some(&b"still here"[..]));
    }

    #[tokio::test]
    async fn an_unknown_token_is_dropped_without_a_reply() {
        let (relay, routes) = relay().await;
        let (client, host) =
            bound_session(relay, &routes, &[CLIENT_TOKEN, HOST_TOKEN]).await;

        // A prober with no session, sending something token-shaped and then something that is not.
        let stranger = UdpSocket::bind(ephemeral()).await.unwrap();
        stranger
            .send_to(&datagram(&[9u8; 16], b"hello?"), relay)
            .await
            .unwrap();
        stranger.send_to(b"not even a token", relay).await.unwrap();

        assert!(
            received(&stranger).await.is_none(),
            "an unbound source should be ignored, not answered"
        );
        assert!(
            received(&host).await.is_none(),
            "and nothing it sends may reach a session it is not part of"
        );
        assert!(
            received(&client).await.is_none(),
            "in either direction"
        );
    }

    #[tokio::test]
    async fn a_datagram_from_the_peers_address_is_dropped() {
        // One end sending with the other's token, from the other's address. Forwarding it would be
        // forwarding it back to where it came from, so the honest answer is to drop it — and to
        // leave both ends exactly where they were rather than let either slot follow it.
        let (relay, routes) = relay().await;
        let (client, host) =
            bound_session(relay, &routes, &[CLIENT_TOKEN, HOST_TOKEN]).await;

        host.send_to(&datagram(&CLIENT_TOKEN, b"stolen"), relay)
            .await
            .unwrap();

        assert!(
            received(&client).await.is_none(),
            "the phone must not be handed the Mac's datagram addressed to it"
        );
        assert!(received(&host).await.is_none(), "nor reflected back at the Mac");

        // Nothing moved: a frame in each direction still takes the ordinary path.
        client
            .send_to(&datagram(&CLIENT_TOKEN, b"up"), relay)
            .await
            .unwrap();
        assert_eq!(received(&host).await.as_deref(), Some(&b"up"[..]));

        host.send_to(&datagram(&HOST_TOKEN, b"down"), relay)
            .await
            .unwrap();
        assert_eq!(received(&client).await.as_deref(), Some(&b"down"[..]));
    }

    #[tokio::test]
    async fn the_relay_carries_payloads_of_any_length_unread() {
        // The relay is a pipe. None of these is a counter followed by a sealed frame and a tag, and
        // the relay cannot tell and must not care: it forwards the bytes it was given, including a
        // payload that is not a whole number of anything.
        let (relay, routes) = relay().await;
        let (client, host) =
            bound_session(relay, &routes, &[CLIENT_TOKEN, HOST_TOKEN]).await;

        for len in [1usize, 3, 7, 8, 16, 17, 24, 1000, 4096] {
            let payload: Vec<u8> = (0..len).map(|byte| (byte % 251) as u8).collect();
            client
                .send_to(&datagram(&CLIENT_TOKEN, &payload), relay)
                .await
                .unwrap();

            assert_eq!(
                received(&host).await.as_deref(),
                Some(payload.as_slice()),
                "a {len}-byte payload should arrive unchanged"
            );
        }
    }

    #[tokio::test]
    async fn two_sessions_share_the_socket_and_do_not_cross() {
        // The point of the whole change: one port, two sessions with video at once, and neither
        // one's frames reaching the other's ends. Under the old design this is what a range of one
        // port made impossible.
        let (relay, routes) = relay().await;
        let first_client_token = [11u8; 16];
        let first_host_token = [12u8; 16];
        let second_client_token = [21u8; 16];
        let second_host_token = [22u8; 16];

        let (first_client, first_host) =
            bound_session(relay, &routes, &[first_client_token, first_host_token]).await;
        let (second_client, second_host) =
            bound_session(relay, &routes, &[second_client_token, second_host_token]).await;
        assert_eq!(routes.len(), 2);

        // Interleaved, because two sessions that only work one at a time would pass a test that
        // sent them in sequence.
        first_host
            .send_to(&datagram(&first_host_token, b"first frame"), relay)
            .await
            .unwrap();
        second_host
            .send_to(&datagram(&second_host_token, b"second frame"), relay)
            .await
            .unwrap();
        first_client
            .send_to(&datagram(&first_client_token, b"first click"), relay)
            .await
            .unwrap();
        second_client
            .send_to(&datagram(&second_client_token, b"second click"), relay)
            .await
            .unwrap();

        assert_eq!(
            received(&first_client).await.as_deref(),
            Some(&b"first frame"[..])
        );
        assert_eq!(
            received(&second_client).await.as_deref(),
            Some(&b"second frame"[..])
        );
        assert_eq!(
            received(&first_host).await.as_deref(),
            Some(&b"first click"[..])
        );
        assert_eq!(
            received(&second_host).await.as_deref(),
            Some(&b"second click"[..])
        );
    }

    #[tokio::test]
    async fn a_session_that_ends_stops_routing_and_leaves_the_others_forwarding() {
        // Teardown, on the one structure that now outlives every session it holds. Closing one
        // session must take its two tokens out without touching the session next to it — a flaw
        // here is a leak that lasts as long as the process does.
        let (relay, routes) = relay().await;
        let closing_client = [31u8; 16];
        let closing_host = [32u8; 16];
        let live_client = [41u8; 16];
        let live_host = [42u8; 16];

        let (closing_client_socket, closing_host_socket) =
            bound_session(relay, &routes, &[closing_client, closing_host]).await;
        let (live_client_socket, live_host_socket) =
            bound_session(relay, &routes, &[live_client, live_host]).await;

        routes.close(&[closing_client, closing_host]);

        closing_host_socket
            .send_to(&datagram(&closing_host, b"nobody"), relay)
            .await
            .unwrap();
        assert!(
            received(&closing_client_socket).await.is_none(),
            "a retired token routes nothing"
        );

        live_host_socket
            .send_to(&datagram(&live_host, b"somebody"), relay)
            .await
            .unwrap();
        assert_eq!(
            received(&live_client_socket).await.as_deref(),
            Some(&b"somebody"[..]),
            "and the session beside it is untouched"
        );
        assert_eq!(routes.len(), 1);
    }

    #[tokio::test]
    async fn the_port_is_the_bound_one_and_port_zero_reports_what_the_os_chose() {
        // What `ready` has to be able to say. With port 0 the OS picks, and the only place that
        // number is known is the socket that was bound, so it has to come back out of `serve`.
        let (relay, _routes) = relay().await;

        assert_ne!(relay.port(), 0, "a port was chosen");

        let explicit = tokio::net::UdpSocket::bind(ephemeral()).await.unwrap();
        let taken = explicit.local_addr().unwrap();
        drop(explicit);

        let routes = Arc::new(VideoRoutes::new());
        let bound = serve(taken, routes, Duration::from_secs(300))
            .await
            .expect("an explicit port should bind");
        assert_eq!(bound, taken, "an explicit port is used as given");
    }
}
