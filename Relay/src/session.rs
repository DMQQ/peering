//! Sessions: the pairing of one phone with one Mac, and the rendezvous that lets two connections
//! that both travelled outbound find each other.
//!
//! **A session is an address, not an authorization.** Everything here exists to answer "which two
//! endpoints belong together", and nothing here decides whether they are *allowed* to talk. That
//! decision is made by the two ends themselves, in the TLS handshake and the pin that follows it,
//! and it is the only reason this relay can be a dumb forwarder without being a security hole.
//!
//! A direct consequence, and one worth being explicit about: the control token is not a secret.
//! It has to be presented in the clear before TLS starts, because TLS is what it is carrying. All
//! it does is claim a place in a splice; someone who steals it gets a connection that fails its
//! handshake.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use rand::Rng;
use tokio::net::TcpStream;
use tokio::sync::{oneshot, Mutex};

/// A 128-bit addressing hint. See the module comment for what it is and is not.
pub type Token = [u8; 16];

pub fn new_token() -> Token {
    let mut token = [0u8; 16];
    rand::rng().fill(&mut token);
    token
}

/// What happened when a connection presented its control token.
pub enum Join {
    /// First to arrive. This side keeps its own stream and waits for the peer's, so it ends up
    /// holding both halves and owns the splice.
    Waiting {
        mine: TcpStream,
        peer: oneshot::Receiver<TcpStream>,
    },

    /// Second to arrive. Our stream has been handed to the side that got here first, and this task
    /// is finished — the connection lives on in theirs.
    HandedOver,
}

/// The two control connections of a session, as they arrive.
#[derive(Default)]
struct ControlPairing {
    waiting: Option<oneshot::Sender<TcpStream>>,
}

/// The two video endpoints of a session, as they bind.
///
/// **Each end holds a different token, and that is the whole design.** The obvious alternative — one
/// shared token — cannot express what a bind packet needs to say. Both ends send the same thing, so
/// the relay cannot tell which slot a re-bind belongs to, and a phone whose carrier NAT moved it
/// mid-session would be indistinguishable from a stranger trying to take a slot. It would also make
/// slot assignment depend on which packet happened to arrive first, so a log line saying "slot 0"
/// would mean the phone or the Mac depending on timing. Two tokens make the mapping fixed: slot 0 is
/// always the client, slot 1 is always the host, whoever gets there first.
///
/// A `std::sync::Mutex` guards this rather than a tokio one because it is touched on the datagram
/// path and nothing here awaits — a tokio mutex would add a queue for no reason.
pub struct VideoPairing {
    /// Indexed by slot: 0 is the client, 1 is the host.
    tokens: [Token; 2],
    addrs: [Option<SocketAddr>; 2],
    last_activity: Option<Instant>,
}

/// Slot 0. The phone.
pub const CLIENT_SLOT: usize = 0;
/// Slot 1. The Mac.
pub const HOST_SLOT: usize = 1;

impl VideoPairing {
    pub fn new(tokens: [Token; 2]) -> Self {
        Self {
            tokens,
            addrs: [None, None],
            last_activity: None,
        }
    }

    /// Claims the slot belonging to `token`, pointing it at `from`.
    ///
    /// Rebinding is the normal path, not an exception: each call simply replaces the address for
    /// that token's slot. A phone whose mapping moved re-sends its bind packet and is immediately
    /// reachable again — which is the one thing the video path has to survive that the control path
    /// does not, because control can reconnect and datagrams cannot.
    ///
    /// Returns `None` for a token that is not one of ours, so an address cannot be inserted into
    /// someone else's session.
    pub fn bind(&mut self, token: &Token, from: SocketAddr) -> Option<u8> {
        // Not a constant-time comparison, and it does not need to be: these tokens travel inside
        // TLS to their intended recipient and are addressing hints rather than credentials. See the
        // module comment.
        let slot = self.tokens.iter().position(|known| known == token)?;
        self.addrs[slot] = Some(from);
        self.last_activity = Some(Instant::now());
        Some(slot as u8)
    }

    /// Where a datagram from `from` should go, if both ends have bound.
    ///
    /// Returns `None` for an unknown source, which is also how a stolen or guessed address is
    /// handled: unbound addresses are dropped without a reply, so the relay never confirms that a
    /// session exists to someone who was not told about it.
    pub fn peer_of(&self, from: &SocketAddr) -> Option<SocketAddr> {
        let slot = self.slot_of(from)?;
        self.addrs[1 - slot as usize]
    }

    fn slot_of(&self, addr: &SocketAddr) -> Option<u8> {
        self.addrs
            .iter()
            .position(|slot| slot.as_ref() == Some(addr))
            .map(|index| index as u8)
    }

    pub fn is_complete(&self) -> bool {
        self.addrs.iter().all(Option::is_some)
    }

    /// How long since this side last moved a byte, used to expire an abandoned session.
    pub fn idle_for(&self) -> Duration {
        self.last_activity
            .map(|at| at.elapsed())
            .unwrap_or_default()
    }
}

/// A session, handed out when a phone asks for a Mac.
pub struct Allocated {
    pub control_token: Token,
    /// One per end, indexed by slot — see [`VideoPairing`]. The two are deliberately different.
    pub video_tokens: [Token; 2],
    /// Shared with the task that owns the session's UDP socket. Nothing else touches it, so it
    /// needs no lookup by token.
    pub video: Arc<std::sync::Mutex<VideoPairing>>,
}

struct Session {
    host_id: String,
    client_id: String,
    video_tokens: [Token; 2],
    control: ControlPairing,
    last_activity: Instant,
}

#[derive(Default)]
struct Inner {
    sessions: HashMap<Token, Session>,
}

pub struct Registry {
    inner: Mutex<Inner>,
}

impl Default for Registry {
    fn default() -> Self {
        Self::new()
    }
}

impl Registry {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(Inner::default()),
        }
    }

    /// Mints a session between a phone and a Mac.
    ///
    /// Any previous session for the same pair is dropped first. One phone talks to one Mac, so two
    /// live sessions for the same pair is always a reconnect that did not clean up rather than
    /// something to support — and without this, a phone reconnecting in a loop would accumulate a
    /// UDP socket per attempt until the sweep caught up.
    ///
    /// Dropping the old session drops its rendezvous channel, which is how the connection still
    /// waiting in it learns to give up.
    pub async fn allocate(&self, host_id: &str, client_id: &str) -> Allocated {
        let control_token = new_token();
        let video_tokens = [new_token(), new_token()];
        let video = Arc::new(std::sync::Mutex::new(VideoPairing::new(video_tokens)));

        let mut inner = self.inner.lock().await;
        inner.sessions.retain(|_, session| {
            !(session.host_id == host_id && session.client_id == client_id)
        });
        inner.sessions.insert(
            control_token,
            Session {
                host_id: host_id.to_string(),
                client_id: client_id.to_string(),
                video_tokens,
                control: ControlPairing::default(),
                last_activity: Instant::now(),
            },
        );

        Allocated {
            control_token,
            video_tokens,
            video,
        }
    }

    /// Presents a control token, and either waits for the peer or hands this stream over to
    /// whoever is already waiting.
    pub async fn join_control(&self, token: &Token, mine: TcpStream) -> Option<Join> {
        let mut inner = self.inner.lock().await;
        let session = inner.sessions.get_mut(token)?;
        session.last_activity = Instant::now();

        // `mine` is moved into the channel in one arm and kept in the other. That is the whole
        // reason `Waiting` carries it back out: whoever waits has to splice, and splicing needs
        // both halves.
        let waiting = session.control.waiting.take();
        Some(match waiting {
            Some(peer) => {
                let _ = peer.send(mine);
                Join::HandedOver
            }
            None => {
                let (tx, rx) = oneshot::channel();
                session.control.waiting = Some(tx);
                Join::Waiting { mine, peer: rx }
            }
        })
    }

    /// Discards a session. Called when a splice ends, so a token cannot be presented twice, and by
    /// the sweep for sessions that never completed.
    pub async fn release(&self, token: &Token) {
        self.inner.lock().await.sessions.remove(token);
    }

    /// Drops sessions with no activity for `ttl`, returning how many went.
    pub async fn sweep(&self, ttl: Duration) -> usize {
        let mut inner = self.inner.lock().await;
        let before = inner.sessions.len();
        inner
            .sessions
            .retain(|_, session| session.last_activity.elapsed() < ttl);
        before - inner.sessions.len()
    }

    pub async fn len(&self) -> usize {
        self.inner.lock().await.sessions.len()
    }

    pub async fn is_empty(&self) -> bool {
        self.len().await == 0
    }

    /// For tests and logs: the client's video token belonging to a control token.
    pub async fn video_token_for(&self, token: &Token) -> Option<Token> {
        self.inner
            .lock()
            .await
            .sessions
            .get(token)
            .map(|session| session.video_tokens[CLIENT_SLOT])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    const CLIENT: Token = [1u8; 16];
    const HOST: Token = [2u8; 16];

    fn addr(last: u8, port: u16) -> SocketAddr {
        SocketAddr::from((Ipv4Addr::new(127, 0, 0, last), port))
    }

    fn pairing() -> VideoPairing {
        VideoPairing::new([CLIENT, HOST])
    }

    #[test]
    fn each_end_gets_its_own_slot_regardless_of_who_binds_first() {
        // The host sends its bind packet first, and still lands in slot 1. Slot assignment follows
        // the token, not arrival order — otherwise "slot 0" in a log would mean the phone or the
        // Mac depending on which packet won a race, and there would be no way to tell which.
        let mut video = pairing();
        assert_eq!(video.bind(&HOST, addr(2, 6000)), Some(1));
        assert_eq!(video.bind(&CLIENT, addr(1, 5000)), Some(0));
        assert!(video.is_complete());

        assert_eq!(video.peer_of(&addr(1, 5000)), Some(addr(2, 6000)));
        assert_eq!(video.peer_of(&addr(2, 6000)), Some(addr(1, 5000)));
    }

    #[test]
    fn a_rebinding_end_keeps_its_slot_and_moves_its_address() {
        // The case this exists for: a carrier NAT moves the phone's mapping mid-session. It
        // re-sends its bind packet from the new address and is reachable again — without becoming
        // a third participant and without displacing the Mac. This is the one failure the video
        // path cannot recover from by reconnecting, because there is no connection to re-establish.
        let mut video = pairing();
        video.bind(&CLIENT, addr(1, 5000));
        video.bind(&HOST, addr(2, 6000));

        assert_eq!(video.bind(&CLIENT, addr(1, 7000)), Some(0), "same slot, new address");
        assert_eq!(video.peer_of(&addr(1, 7000)), Some(addr(2, 6000)));
        assert_eq!(video.peer_of(&addr(2, 6000)), Some(addr(1, 7000)), "the host follows");
        assert_eq!(
            video.peer_of(&addr(1, 5000)),
            None,
            "the old mapping is gone, not a second participant"
        );
    }

    #[test]
    fn a_token_can_only_move_its_own_slot() {
        // Presenting the Mac's token moves the Mac. It does not let whoever holds it take the
        // client's slot, which one shared token could not have expressed.
        let mut video = pairing();
        video.bind(&CLIENT, addr(1, 5000));
        video.bind(&HOST, addr(2, 6000));

        assert_eq!(video.bind(&HOST, addr(3, 7000)), Some(1));
        assert_eq!(video.peer_of(&addr(1, 5000)), Some(addr(3, 7000)));
        assert_eq!(video.peer_of(&addr(3, 7000)), Some(addr(1, 5000)));
    }

    #[test]
    fn a_token_that_was_never_issued_binds_nothing() {
        let mut video = pairing();
        assert_eq!(video.bind(&[9u8; 16], addr(1, 5000)), None);
        assert_eq!(video.peer_of(&addr(1, 5000)), None);
    }

    #[test]
    fn an_unknown_source_has_no_peer_and_does_not_get_a_reply() {
        let mut video = pairing();
        video.bind(&CLIENT, addr(1, 5000));

        assert_eq!(video.peer_of(&addr(9, 9999)), None);
    }

    #[tokio::test]
    async fn allocate_hands_out_distinct_tokens() {
        let registry = Registry::new();
        let a = registry.allocate("mac", "phone").await;
        let b = registry.allocate("mac", "other-phone").await;

        assert_ne!(a.control_token, b.control_token);
        assert_ne!(a.video_tokens, b.video_tokens);
        // And the two ends of one session do not share theirs either. That is what makes a re-bind
        // unambiguous, and it is why the two `SessionReady` messages differ.
        assert_ne!(a.video_tokens[CLIENT_SLOT], a.video_tokens[HOST_SLOT]);
        assert_eq!(registry.len().await, 2);
    }

    #[tokio::test]
    async fn reallocating_for_the_same_pair_supersedes_the_old_session() {
        let registry = Registry::new();
        let first = registry.allocate("mac", "phone").await;
        let second = registry.allocate("mac", "phone").await;

        assert_eq!(registry.len().await, 1, "one phone, one Mac, one session");
        assert!(registry.video_token_for(&first.control_token).await.is_none());
        assert!(registry.video_token_for(&second.control_token).await.is_some());
    }

    #[tokio::test]
    async fn the_first_connection_waits_and_the_second_hands_itself_over() {
        let registry = Registry::new();
        let allocated = registry.allocate("mac", "phone").await;
        let token = allocated.control_token;

        // Stand-ins for the two live sockets; the pairing logic only moves them around.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let listener_addr = listener.local_addr().unwrap();
        let first_socket = TcpStream::connect(listener_addr).await.unwrap();
        let second_socket = TcpStream::connect(listener_addr).await.unwrap();

        let first = registry.join_control(&token, first_socket).await;
        let second = registry.join_control(&token, second_socket).await;
        assert!(matches!(second, Some(Join::HandedOver)));

        // The side that arrived first keeps its own stream and receives the side that arrived
        // second, so it holds both halves and can splice them. Getting this wrong — moving our own
        // stream into the channel and never getting it back — leaves the waiter with one half and
        // nothing to splice it to, which is exactly what this asserts against.
        let Some(Join::Waiting { mine, peer }) = first else {
            panic!("the first connection should be the one waiting");
        };
        assert!(mine.peer_addr().is_ok(), "the waiter keeps its own stream");
        assert!(peer.await.is_ok(), "the peer's stream should arrive");
    }

    #[tokio::test]
    async fn a_token_that_was_never_issued_joins_nothing() {
        let registry = Registry::new();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let socket = TcpStream::connect(listener.local_addr().unwrap()).await.unwrap();

        assert!(registry.join_control(&[0xff; 16], socket).await.is_none());
    }

    #[tokio::test]
    async fn releasing_a_session_makes_its_token_useless() {
        let registry = Registry::new();
        let allocated = registry.allocate("mac", "phone").await;
        registry.release(&allocated.control_token).await;

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let socket = TcpStream::connect(listener.local_addr().unwrap()).await.unwrap();
        assert!(registry
            .join_control(&allocated.control_token, socket)
            .await
            .is_none());
    }

    #[tokio::test]
    async fn the_sweep_takes_abandoned_sessions_and_leaves_busy_ones() {
        let registry = Registry::new();
        registry.allocate("mac", "phone").await;

        assert_eq!(registry.sweep(Duration::from_secs(300)).await, 0);
        assert_eq!(registry.sweep(Duration::ZERO).await, 1);
        assert!(registry.is_empty().await);
    }
}
