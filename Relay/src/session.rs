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
//!
//! The video tokens are the same kind of thing, and the shared video socket makes that visible
//! rather than theoretical: a video token is the prefix of every datagram it sends, in the clear,
//! on a port that anyone can reach. Someone who reads one can claim the slot it names and redirect
//! or stop the video that was going to that end. They cannot read a frame of it, and they cannot
//! forge one: the payload is sealed with a key this process was never told, and the tag is not
//! ours to check. A token is a claim on a place in the forward, never a key to what passes through
//! it — and if that ever stops being true, this file is where the mistake will be.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex as StdMutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use rand::Rng;
use tokio::net::TcpStream;
use tokio::sync::{oneshot, Mutex};

use crate::quota::Account;

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
    /// Whether both halves have ever been present.
    ///
    /// **A control token is meant to be presented once by each side, and this is what makes that
    /// true.** The waiting slot empties again as soon as a pair has been joined, so without this a
    /// third connection presenting the same token became a fresh waiter and a fourth was spliced to
    /// it: whoever learned a token could sit in the middle of a live session, lock the real end out
    /// of its own splice, and have a second splice charged to the account the token belongs to.
    /// Reading the traffic was never possible, which is why this is about availability and
    /// accounting rather than about the session's contents.
    paired: bool,
}

/// Slot 0. The phone.
pub const CLIENT_SLOT: usize = 0;
/// Slot 1. The Mac.
pub const HOST_SLOT: usize = 1;

/// Names one session inside the routing table, so a session's two routes can be talked about as one
/// thing without naming a token. Minted here rather than taken from a token, because a token is an
/// addressing hint that has no business being copied into a log line.
pub type SessionId = u64;

/// One end's place in the routing table: which session a token belongs to, which end is its peer,
/// and where that end has been heard from.
///
/// There is no slot number here, and that is deliberate rather than an omission. A route knows its
/// peer's token, and a session has exactly two slots, so "the other slot's address" is the peer's
/// address and a number would only restate which of the two this is. Carrying the peer's token
/// instead is what keeps this one table: the alternative keys routes by session and slot and needs
/// a second table to get from a token to them, and two tables can be made to disagree.
#[derive(Debug, Clone, Copy)]
struct Route {
    /// Both of a session's routes carry the same id, which is what lets a sweep of the table take a
    /// session's two ends away together.
    session: SessionId,
    /// The other end's token, so its address is one more lookup in this table rather than a second
    /// table that would have to be kept in step with this one.
    peer: Token,
    /// Where this end is, once a datagram has arrived from it.
    ///
    /// **The datagram's source address is the binding.** There is no separate handshake that
    /// records it and no state that survives an end moving: a datagram from a new address moves the
    /// slot to that address, which is what lets a carrier NAT change a mapping mid-session and the
    /// video resume without either end having to notice it happened.
    addr: Option<SocketAddr>,
    /// When a datagram last arrived from this end. A session's own clock is the later of its two,
    /// because a session has not gone quiet while either end is still talking — see
    /// [`Table::has_gone_quiet`].
    last_active: Option<Instant>,
}

/// What the routing table made of one datagram's token.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Routed {
    /// The sender's address is bound to this token's slot, and the other end is at this address.
    /// Whatever followed the token goes there.
    Peer(SocketAddr),
    /// The sender is bound and the other end has not claimed its slot, so there is nowhere to send
    /// it. Not an error and not worth counting: it is the ordinary state of a session whose second
    /// end has not started yet.
    NoPeer,
    /// Nothing was bound and nothing is sent: either no session holds this token, or the address it
    /// arrived from already holds the other slot of the session it claims.
    Dropped,
}

/// The relay's video routing table: every live session's tokens, and where each of its ends is.
///
/// **One table, because there is one socket.** The token in a datagram's first sixteen bytes is the
/// whole of the demultiplexer — `udp_relay` carries the wire shape and the argument for it — so this
/// answers "whose datagram is this, and where does it go" in one lookup, for every session at once.
///
/// **Each end still holds a different token, and that is still the whole design.** One shared token
/// cannot express what a binding has to say: both ends would send the same prefix, so the relay
/// could not attribute a re-bind to a slot, and a phone whose carrier moved its NAT mapping
/// mid-session would be indistinguishable from a stranger taking the Mac's place. It would also make
/// a slot depend on which packet happened to arrive first, so "slot 0" in a log would mean the phone
/// or the Mac depending on timing. Two tokens make the mapping fixed — slot 0 is always the client,
/// slot 1 is always the host, whoever speaks first — and make "this address is already the other
/// end" a question with an answer.
///
/// A `std::sync::Mutex` guards this rather than a tokio one, for the same reason it did when it
/// guarded one session's pairing: it is taken on the datagram path and nothing here awaits, so a
/// tokio mutex would add a queue for no reason. What it now holds across is a lookup, a store and
/// the address to send to — never the send itself, which happens after the guard is released.
pub struct VideoRoutes {
    inner: StdMutex<Table>,
}

#[derive(Default)]
struct Table {
    routes: HashMap<Token, Route>,
    /// Hands out [`SessionId`]s. Never reused, so an id means one session for the life of the
    /// process and a stale id in a log line can be told from a live one.
    minted: SessionId,
}

impl Default for VideoRoutes {
    fn default() -> Self {
        Self::new()
    }
}

impl VideoRoutes {
    pub fn new() -> Self {
        Self {
            inner: StdMutex::new(Table::default()),
        }
    }

    /// Registers both ends of a new session.
    ///
    /// Nothing else puts a token in the table, so an unknown token stays unknown: there is no path
    /// by which traffic can create a route, and therefore none by which a stranger can invent a
    /// session to be forwarded into.
    pub fn open(&self, tokens: &[Token; 2]) {
        let mut inner = lock(&self.inner);
        let session = inner.minted;
        inner.minted += 1;

        // Both halves under one lock, so no datagram can find half a session in the table.
        for (slot, token) in tokens.iter().enumerate() {
            inner.routes.insert(
                *token,
                Route {
                    session,
                    peer: tokens[1 - slot],
                    addr: None,
                    last_active: None,
                },
            );
        }
    }

    /// Retires both ends of a session. Called wherever a session ends: released when its control
    /// splice finishes, superseded by a reconnect, or swept for having gone quiet.
    ///
    /// **The pair goes together.** A route left behind is a token that still forwards, towards an
    /// address that will never answer again — and it would now be left behind in a table that
    /// outlives every session instead of in a socket that died with one. That is why teardown is a
    /// call here rather than a dropped handle somewhere, and why every path that removes a session
    /// from the registry calls it.
    pub fn close(&self, tokens: &[Token; 2]) {
        let mut inner = lock(&self.inner);
        for token in tokens {
            inner.routes.remove(token);
        }
    }

    /// Routes one datagram's token, binding the address it arrived from as it goes.
    ///
    /// Every datagram re-states its sender's address, so every datagram is a bind: a re-bind is not
    /// a special case here but the ordinary path, and it is what makes a NAT mapping that moves
    /// survivable. The alternative — binding once and trusting the address after that — gives a
    /// stream that stops with nothing to reconnect, because datagrams have no connection to
    /// re-establish.
    pub fn route(&self, token: &Token, from: SocketAddr) -> Routed {
        let mut inner = lock(&self.inner);
        let Some(route) = inner.routes.get(token).copied() else {
            return Routed::Dropped;
        };

        // Read before anything is written, and the read is the check. An address that already holds
        // the *other* slot of this session cannot claim this one: the send that would follow is a
        // send back to the address that just sent, so the relay would be reflecting an end's own
        // bytes at it, and a stream that feeds itself never drains. Refusing is also the answer for
        // two ends that arrive from one address for any other reason — one NAT in front of both, a
        // client that bound the peer's port — where every forward would be that same reflection.
        let peer = inner.routes.get(&route.peer).and_then(|peer| peer.addr);
        if peer == Some(from) {
            return Routed::Dropped;
        }

        // The entry was read under this same guard and nothing above this line awaits, so it is
        // still there and `get_mut` cannot be `None`. The branch is here rather than an `expect`
        // because the two ways of being wrong are not equal: a router that panicked would take
        // every session's video with it, and this one would at worst drop a binding that the
        // sender's next datagram makes again.
        if let Some(route) = inner.routes.get_mut(token) {
            route.addr = Some(from);
            route.last_active = Some(Instant::now());
        }

        match peer {
            Some(peer) => Routed::Peer(peer),
            None => Routed::NoPeer,
        }
    }

    /// Where one end's *peer* was last seen, if it has been seen at all.
    ///
    /// The same lookup [`route`](Self::route) does, minus the binding, and read-only: this answers a
    /// question that arrived over signalling rather than a datagram, so there is no sender to bind
    /// and nothing to forward. The lookup is by token rather than by session because a token is what
    /// tells the relay *which* of the two slots is asking — the address that comes back is the
    /// other one.
    ///
    /// `None` covers both "no session holds this token" and "the peer has not spoken yet", and the
    /// two are deliberately one answer: to the only question the caller has — is there anywhere to
    /// point this end — they are the same fact, and a distinct error for each would invite the
    /// client to treat one as retryable and the other as fatal when both are simply early.
    /// Where the *other* end of this session is, spoken in a way the asker can use.
    ///
    /// **The spelling is the whole of this function, and getting it wrong made the direct path
    /// impossible for everybody.** This socket is bound on `[::]`, so a datagram from a client on
    /// IPv4 arrives with a v4-mapped source address and renders as `::ffff:203.0.113.7`. The asker
    /// has an `AF_INET` socket, because that is what resolving the relay over IPv4 gives it, and
    /// `getaddrinfo` with `AF_INET` and `AI_NUMERICHOST` **refuses a v4-mapped literal outright**:
    ///
    /// ```text
    /// ::ffff:203.0.113.7   AF_INET   -> fails
    /// 203.0.113.7          AF_INET   -> works
    /// 203.0.113.7          AF_INET6  -> fails
    /// 2001:db8::1          AF_INET6  -> works
    /// ```
    ///
    /// Neither end could resolve what this handed it, both call sites discard the error, and so
    /// neither ever sent a probe and neither ever said so. Every session stayed on the relay and
    /// the whole feature was inert, which looked exactly like two NATs that would not cooperate.
    ///
    /// So the mapping is folded away for a v4 asker, and a peer in the *other* family is not
    /// offered at all: an address the asker's socket cannot parse is worse than no answer, because
    /// the answer is what the asker retries on and "no address yet" is at least honest.
    pub fn peer_address(&self, token: &Token) -> Option<SocketAddr> {
        let inner = lock(&self.inner);
        let route = inner.routes.get(token)?;
        let peer = fold(inner.routes.get(&route.peer)?.addr?);

        // The asker's own address is what says which spelling it can parse, and on the very first
        // ask it is often not known yet: the client asks before it has sent anything, because the
        // answer is what tells it where to send. That is ordinary and the caller asks again; what
        // it gets in the meantime is the peer folded, which is still better than the raw form,
        // because the raw form is what nothing could parse.
        let Some(mine) = route.addr.map(fold) else { return Some(peer) };

        match (mine, peer) {
            (SocketAddr::V4(_), SocketAddr::V4(_)) | (SocketAddr::V6(_), SocketAddr::V6(_)) => {
                Some(peer)
            }
            // One end on IPv4 and the other on IPv6, with no common address family: there is no
            // path between them to find, and saying nothing is the accurate answer.
            _ => None,
        }
    }

    /// Drops sessions that have heard nothing from either end for `idle_ttl`, returning how many
    /// went.
    ///
    /// A session that has never carried a datagram has no clock at all and is left alone: it is
    /// unstarted rather than idle, and what ends it is the registry's own sweep. `Duration::ZERO`
    /// therefore takes every session that has ever spoken and no session that has not, which is
    /// what a test wants to say without waiting, and is close to what an operator is asking when
    /// they ask whether this table holds only sessions that are still alive.
    pub fn reap(&self, idle_ttl: Duration) -> usize {
        let mut inner = lock(&self.inner);

        // Collected before anything is removed, so no decision is taken about a table a previous
        // removal has already changed. Grouped by session, because the pair is what goes: an end
        // whose other end is still talking has not gone quiet, and half a session left behind is
        // the state this file exists to avoid.
        let mut expired: HashMap<SessionId, [Token; 2]> = HashMap::new();
        for (token, route) in inner.routes.iter() {
            if inner.has_gone_quiet(route, idle_ttl) {
                expired.entry(route.session).or_insert([*token, route.peer]);
            }
        }

        for pair in expired.values() {
            inner.routes.remove(&pair[0]);
            inner.routes.remove(&pair[1]);
        }
        expired.len()
    }

    /// The number of live sessions. Two routes each, so half the table.
    pub fn len(&self) -> usize {
        lock(&self.inner).routes.len() / 2
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

impl Table {
    /// Whether a session has been silent from **both** ends for longer than `idle_ttl`.
    ///
    /// Both, because the clock that decides is the later of the two ends': a session whose Mac is
    /// still sending frames is alive whatever its phone last said. A session that has never carried
    /// a datagram has no clock and is not idle — nothing has started yet.
    fn has_gone_quiet(&self, route: &Route, idle_ttl: Duration) -> bool {
        let peer = self
            .routes
            .get(&route.peer)
            .and_then(|peer| peer.last_active);

        let last = match (route.last_active, peer) {
            (Some(mine), Some(theirs)) => Some(mine.max(theirs)),
            (mine, theirs) => mine.or(theirs),
        };
        last.is_some_and(|at| at.elapsed() >= idle_ttl)
    }
}

/// A poisoned lock only means some other task panicked while holding it, and the data here — tokens
/// and addresses — cannot be left inconsistent by a panic: every mutation is one insert, one remove
/// or a field assignment. Recovering beats propagating, which would now take the video of every
/// session down at once over one session's bookkeeping.
/// A peer's address as the family it actually is, with the v4-mapping folded away.
///
/// `SocketAddr::is_ipv4` answers `false` for a v4-mapped address, because it is an `Ipv6Addr` with
/// an IPv4 address inside it, which is exactly the trap this whole bug was made of. Everything
/// here works on the folded form so that "is this end on IPv4" means what it says.
fn fold(address: SocketAddr) -> SocketAddr {
    match address {
        SocketAddr::V4(_) => address,
        SocketAddr::V6(v6) => match v6.ip().to_ipv4_mapped() {
            Some(v4) => SocketAddr::new(std::net::IpAddr::V4(v4), v6.port()),
            None => address,
        },
    }
}

fn lock(inner: &StdMutex<Table>) -> MutexGuard<'_, Table> {
    inner.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A session, handed out when a phone asks for a Mac.
pub struct Allocated {
    pub control_token: Token,
    /// One per end, indexed by slot — see [`VideoRoutes`]. The two are deliberately different, and
    /// both are already in the routing table by the time this is handed out.
    pub video_tokens: [Token; 2],
}

struct Session {
    host_id: String,
    client_id: String,
    /// Who this session's relay time is charged to, and on what terms.
    ///
    /// **Here for the same reason `client_id` is**: the splice runs in `tcp_relay`, which by then
    /// holds a control token and two sockets and nothing else, so what it needs to meter the
    /// connection has to travel with the session and be handed over when the token is. See
    /// `quota::Account`.
    account: Account,
    /// Kept so the session's routes can be retired when it ends. The table itself is the only place
    /// that knows where the ends are; this is the key to it.
    video_tokens: [Token; 2],
    control: ControlPairing,
    last_activity: Instant,
}

struct Inner {
    sessions: HashMap<Token, Session>,
    /// See `Settings::max_sessions`. Carried here rather than passed to every `allocate` so that the
    /// ceiling cannot be forgotten by one caller and not another.
    max_sessions: usize,
}

/// The default is "no ceiling", which is what every test that is not about the ceiling wants. It is
/// deliberately not what the binary uses: `Registry::new` takes the number, and `main` takes it from
/// the environment.
impl Default for Inner {
    fn default() -> Self {
        Self {
            sessions: HashMap::new(),
            max_sessions: usize::MAX,
        }
    }
}

pub struct Registry {
    inner: Mutex<Inner>,
    /// The video routing table, shared with the task that owns the relay's one video socket.
    ///
    /// Held here rather than beside that socket because a session *is* what a route belongs to: the
    /// tokens are minted in `allocate` and the routes are retired wherever the session ends. Held
    /// as an `Arc` and locked with a `std::sync::Mutex` inside, so the datagram path never waits on
    /// this registry's own lock — see [`VideoRoutes`].
    ///
    /// **Lock order, if anyone ever takes both: this one first, always.** Nothing on the datagram
    /// path takes this lock at all, so the two cannot deadlock; the rule is here so that stays true.
    routes: Arc<VideoRoutes>,
}

impl Default for Registry {
    fn default() -> Self {
        Self::new(usize::MAX)
    }
}

impl Registry {
    /// A registry that will not hand out more than `max_sessions` at once.
    ///
    /// The number is a parameter rather than a constant because it belongs to the deployment rather
    /// than to this module: the binary passes `PEERINGD_MAX_SESSIONS`, and a test that does not
    /// care passes `usize::MAX`. See `Settings::max_sessions` for why there is a ceiling at all.
    pub fn new(max_sessions: usize) -> Self {
        Self {
            inner: Mutex::new(Inner {
                max_sessions,
                ..Inner::default()
            }),
            routes: Arc::new(VideoRoutes::new()),
        }
    }

    /// The video routing table, for the task that owns the relay's one socket.
    pub fn routes(&self) -> Arc<VideoRoutes> {
        Arc::clone(&self.routes)
    }

    /// Mints a session between a phone and a Mac, and opens its video routes.
    ///
    /// Any previous session for the same pair is dropped first. One phone talks to one Mac, so two
    /// live sessions for the same pair is always a reconnect that did not clean up rather than
    /// something to support — and without this, a phone reconnecting in a loop would accumulate a
    /// session per attempt until the sweep caught up.
    ///
    /// Dropping the old session drops its rendezvous channel, which is how the connection still
    /// waiting in it learns to give up.
    ///
    /// `account` is what the session will be metered on, resolved by the caller from the plan
    /// `storekit` decided: this module knows nothing about plans or money, and takes what it is
    /// given. It is dropped with a superseded session, and a splice that is already running holds a
    /// copy of it, which is why replacing a session does not stop the one it replaced from being
    /// charged for as long as it lasts.
    /// **`None` means the relay is at its ceiling**, and the caller has to say so rather than
    /// pretend a session exists. See `Settings::max_sessions` for what that ceiling is for.
    pub async fn allocate(
        &self,
        host_id: &str,
        client_id: &str,
        account: Account,
    ) -> Option<Allocated> {
        let control_token = new_token();
        let video_tokens = [new_token(), new_token()];

        let mut inner = self.inner.lock().await;

        // Superseded sessions are collected rather than merely dropped: their video routes have to
        // leave the table with them, and there is no `Drop` on a route that would do it.
        let mut retired: Vec<[Token; 2]> = Vec::new();
        inner.sessions.retain(|_, session| {
            let superseded = session.host_id == host_id && session.client_id == client_id;
            if superseded {
                retired.push(session.video_tokens);
            }
            !superseded
        });

        // **After the retain, not before it.** A phone reconnecting to a Mac it already has a
        // session with is not asking for a new one, and refusing it because the relay happens to be
        // full would strand the one session it does not need a second of.
        if inner.sessions.len() >= inner.max_sessions {
            return None;
        }

        inner.sessions.insert(
            control_token,
            Session {
                host_id: host_id.to_string(),
                client_id: client_id.to_string(),
                account,
                video_tokens,
                control: ControlPairing::default(),
                last_activity: Instant::now(),
            },
        );

        // Opened and retired under the same lock as the session itself, so the table and the
        // registry can never be seen disagreeing. Doing it after the lock would leave a window in
        // which two allocations for one pair could have the loser open routes the winner had
        // already closed, and a route nothing will ever retire is exactly the leak this is for.
        self.routes.open(&video_tokens);
        for tokens in &retired {
            self.routes.close(tokens);
        }

        Some(Allocated {
            control_token,
            video_tokens,
        })
    }

    /// Presents a control token, and either waits for the peer or hands this stream over to
    /// whoever is already waiting.
    pub async fn join_control(&self, token: &Token, mine: TcpStream) -> Option<Join> {
        let mut inner = self.inner.lock().await;
        let session = inner.sessions.get_mut(token)?;

        // A token that has already been presented by both ends is spent. `None` rather than a
        // refusal of some kind, because a caller cannot tell a probe from an owner and a caller
        // that learns nothing is the right answer to both: the connection is closed without a
        // reply, which is what the caller does with `None` already.
        if session.control.paired {
            return None;
        }
        session.last_activity = Instant::now();

        // `mine` is moved into the channel in one arm and kept in the other. That is the whole
        // reason `Waiting` carries it back out: whoever waits has to splice, and splicing needs
        // both halves.
        let waiting = session.control.waiting.take();
        Some(match waiting {
            Some(peer) => {
                session.control.paired = true;
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
    ///
    /// Retires the session's video routes with it. A session that is gone but still routable is a
    /// token that forwards for a phone that has hung up — and on the shared socket there is no
    /// socket closing behind it to make that harmless.
    pub async fn release(&self, token: &Token) {
        let mut inner = self.inner.lock().await;
        let retired = inner.sessions.remove(token).map(|session| session.video_tokens);
        if let Some(tokens) = retired {
            self.routes.close(&tokens);
        }
    }

    /// Says that a session's own splice is still running.
    ///
    /// **The clock this replaces was the bug.** Activity used to be refreshed only by
    /// ``join_control``, which happens once, when both ends present their token and the splice
    /// starts. Nothing refreshed it afterwards, so a session that was working perfectly was
    /// indistinguishable from an abandoned one for the sweep's purposes: at the TTL, which is five
    /// minutes by default and thirty seconds of sweep apart, the session was retired and its video
    /// routes closed. The picture stopped while the control connection carried on, because the
    /// splice holds its two streams directly rather than through the registry. A relayed session
    /// therefore lost its video five minutes in, every time, and nothing in the log said why.
    ///
    /// Called from the splice's own meter tick, which is the only thing that knows the session is
    /// still doing work. A session nobody ever joined is not touched by anything and is still
    /// swept, which is what the sweep is for.
    pub async fn touch(&self, token: &Token) {
        let mut inner = self.inner.lock().await;
        if let Some(session) = inner.sessions.get_mut(token) {
            session.last_activity = Instant::now();
        }
    }

    /// Drops sessions with no activity for `ttl`, returning how many went.
    pub async fn sweep(&self, ttl: Duration) -> usize {
        let mut inner = self.inner.lock().await;

        let mut retired: Vec<[Token; 2]> = Vec::new();
        let before = inner.sessions.len();
        inner.sessions.retain(|_, session| {
            let expired = session.last_activity.elapsed() >= ttl;
            if expired {
                retired.push(session.video_tokens);
            }
            !expired
        });

        for tokens in &retired {
            self.routes.close(tokens);
        }

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

    /// What a control token's session is metered on, for the TCP relay to charge as it splices.
    ///
    /// **A copy rather than a borrow**, and the reason is the sweep: a session can leave this table
    /// while its splice is still running, and a meter that had reached back into the registry for
    /// its terms would find them gone and stop charging. What the splice needs is settled when the
    /// session is allocated, so this hands over a clone of exactly that and nothing later can
    /// change it.
    pub async fn account_for_token(&self, token: &Token) -> Option<Account> {
        self.inner
            .lock()
            .await
            .sessions
            .get(token)
            .map(|session| session.account.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    use crate::config::PlanAllowances;
    use crate::quota::{Plan, QuotaTracker};

    const CLIENT: Token = [1u8; 16];
    const HOST: Token = [2u8; 16];

    /// A free client's account, with the tracker behind it handed back as well.
    ///
    /// The tests in this module are about the registry rather than about money, so what the account
    /// says is never read: what matters is that a session has one to carry and to hand to a splice.
    /// The tracker comes back beside it so that a test which wants to know what was charged can
    /// look, and so that the `Arc` in the account is plainly not the only handle to it.
    fn client_account() -> (Arc<QuotaTracker>, Account) {
        let tracker = Arc::new(QuotaTracker::new(PlanAllowances::default(), Default::default()));
        let account = tracker.account("phone", None, Plan::Free);
        (tracker, account)
    }

    fn addr(last: u8, port: u16) -> SocketAddr {
        SocketAddr::from((Ipv4Addr::new(127, 0, 0, last), port))
    }

    /// **The ceiling, and the attack it is for.** Nothing authenticates a session request: anyone
    /// who can open a signalling connection can invent a client id and ask for a session, so
    /// without this a loop that varies the id creates a session per message until the box runs out
    /// of memory, and every session it creates outlives the socket that asked for it.
    #[tokio::test]
    async fn the_registry_refuses_past_its_ceiling() {
        let registry = Registry::new(2);
        let (_quota, account) = client_account();

        assert!(registry.allocate("mac", "phone-one", account.clone()).await.is_some());
        assert!(registry.allocate("mac", "phone-two", account.clone()).await.is_some());
        assert!(
            registry.allocate("mac", "phone-three", account).await.is_none(),
            "the third session is refused rather than allocated"
        );
        assert_eq!(registry.len().await, 2, "and nothing was inserted");
    }

    /// **A reconnect at the ceiling is not a new session.** A phone asking for a Mac it already has
    /// a session with is replacing that session, not adding one, and refusing it would strand the
    /// one client that is doing exactly the right thing while the relay is busy.
    #[tokio::test]
    async fn a_reconnect_at_the_ceiling_replaces_its_own_session() {
        let registry = Registry::new(1);
        let (_quota, account) = client_account();

        let first = registry.allocate("mac", "phone", account.clone()).await;
        assert!(first.is_some());
        let first_token = first.expect("just checked").control_token;

        let second = registry.allocate("mac", "phone", account.clone()).await;
        assert!(second.is_some(), "the same pair again is a replacement, not a new session");
        assert!(
            registry.video_token_for(&first_token).await.is_none(),
            "and the session it replaced is gone"
        );

        assert!(
            registry.allocate("mac", "someone-else", account).await.is_none(),
            "while a different pair is still refused"
        );
    }

    /// What `recv_from` on a dual-stack socket reports for a client that is on IPv4: an IPv6
    /// address with the IPv4 one inside it. This is the shape the bug was made of, so the tests
    /// have to be able to produce it.
    fn mapped(a: u8, b: u8, c: u8, d: u8, port: u16) -> SocketAddr {
        SocketAddr::new(
            std::net::IpAddr::V6(Ipv4Addr::new(a, b, c, d).to_ipv6_mapped()),
            port,
        )
    }

    /// A token for session `n`, so a test with many sessions can name them without listing them.
    fn token(n: u8) -> Token {
        [n; 16]
    }

    /// The bug that made the direct path impossible for everybody.
    ///
    /// This socket is bound on `[::]`, so a client on IPv4 is seen as `::ffff:a.b.c.d`. That string
    /// resolves under `AF_INET6` and **fails under `AF_INET`**, which is the family the client's
    /// socket actually has. So both ends were handed an address neither could parse, both discarded
    /// the error, and neither ever sent a probe. Every session stayed on the relay, which on screen
    /// is indistinguishable from two NATs that will not cooperate.
    #[test]
    fn an_ipv4_peer_is_given_as_ipv4_and_not_as_a_mapped_ipv6_address() {
        let routes = VideoRoutes::new();
        routes.open(&[CLIENT, HOST]);

        // What `recv_from` on a dual-stack socket hands back for an IPv4 client.
        routes.route(&CLIENT, mapped(203, 0, 113, 7, 4000));
        routes.route(&HOST, mapped(198, 51, 100, 9, 5000));

        assert_eq!(
            routes.peer_address(&HOST),
            Some(SocketAddr::from((Ipv4Addr::new(203, 0, 113, 7), 4000))),
            "the asker is on IPv4, so the answer has to be a plain IPv4 address"
        );
        assert!(routes.peer_address(&HOST).unwrap().is_ipv4());

        // And the same in the other direction, because both ends ask.
        assert_eq!(
            routes.peer_address(&CLIENT),
            Some(SocketAddr::from((Ipv4Addr::new(198, 51, 100, 9), 5000)))
        );
    }

    /// And when the two ends are in different families there is nothing to hand over, because an
    /// address the asker's socket cannot parse is worse than no answer: the asker retries on an
    /// answer, and "not yet" is at least true.
    #[test]
    fn ends_in_different_families_are_not_introduced() {
        let routes = VideoRoutes::new();
        routes.open(&[CLIENT, HOST]);

        routes.route(&CLIENT, mapped(203, 0, 113, 7, 4000));
        routes.route(&HOST, SocketAddr::from(([0x2a00, 0x1450, 0x4001, 0, 0, 0, 0, 1], 5000)));

        assert_eq!(routes.peer_address(&HOST), None);
        assert_eq!(routes.peer_address(&CLIENT), None);
    }

    /// A genuine IPv6 peer is offered as IPv6, unfolded, to an asker that is on IPv6.
    #[test]
    fn two_ipv6_ends_are_introduced_as_ipv6() {
        let routes = VideoRoutes::new();
        routes.open(&[CLIENT, HOST]);

        let client = SocketAddr::from(([0x2a00, 0x1450, 0x4001, 0, 0, 0, 0, 2], 4000));
        let host = SocketAddr::from(([0x2a00, 0x1450, 0x4001, 0, 0, 0, 0, 1], 5000));
        routes.route(&CLIENT, client);
        routes.route(&HOST, host);

        assert_eq!(routes.peer_address(&HOST), Some(client));
        assert_eq!(routes.peer_address(&CLIENT), Some(host));
    }

    /// The introduction the relay can now give: where one end's peer was last seen.
    ///
    /// "Unknown" is the ordinary state of a session whose second end has not started yet, and it is
    /// the state a client asks in — it asks *before* it has sent anything, because the answer is
    /// what tells it where to send. So the `None` here is the expected first answer rather than a
    /// failure, and the tests below are about which end learns what once the datagrams arrive.
    #[test]
    fn a_peer_address_appears_once_the_other_end_has_been_heard() {
        let routes = VideoRoutes::new();
        routes.open(&[CLIENT, HOST]);

        assert_eq!(routes.peer_address(&CLIENT), None, "nobody has spoken yet");
        assert_eq!(routes.peer_address(&HOST), None);

        routes.route(&CLIENT, addr(1, 4000));

        assert_eq!(
            routes.peer_address(&HOST),
            Some(addr(1, 4000)),
            "the end that has not spoken can be told where the one that has, is"
        );
        assert_eq!(
            routes.peer_address(&CLIENT),
            None,
            "and the end that spoke is told nothing, because its peer has not been heard"
        );

        routes.route(&HOST, addr(2, 5000));
        assert_eq!(routes.peer_address(&CLIENT), Some(addr(2, 5000)));
        assert_eq!(routes.peer_address(&HOST), Some(addr(1, 4000)));
    }

    /// A carrier NAT that moves a mapping mid-session is the thing the binding exists for, and the
    /// answer has to move with it: an end told an address that stopped working would try the direct
    /// path, fail, and fall back — which is survivable but is exactly the latency this is for.
    #[test]
    fn a_peer_address_follows_a_rebind() {
        let routes = VideoRoutes::new();
        routes.open(&[CLIENT, HOST]);
        routes.route(&CLIENT, addr(1, 4000));
        routes.route(&HOST, addr(2, 5000));

        routes.route(&HOST, addr(3, 6000));

        assert_eq!(routes.peer_address(&CLIENT), Some(addr(3, 6000)));
    }

    /// Nothing is learned by asking with a token the table does not hold, and asking must not be a
    /// way to put anything *into* the table either — the write path is `route`, and it needs a
    /// datagram.
    #[test]
    fn an_unknown_token_has_no_peer_address() {
        let routes = VideoRoutes::new();
        assert_eq!(routes.peer_address(&token(9)), None);

        routes.open(&[CLIENT, HOST]);
        assert_eq!(
            routes.peer_address(&token(9)),
            None,
            "and stays unknown once a session exists"
        );
    }

    fn routes() -> VideoRoutes {
        VideoRoutes::new()
    }

    #[test]
    fn each_end_has_its_own_slot_regardless_of_who_speaks_first() {
        // The host speaks first and still lands in slot 1. Slots follow the token, not arrival
        // order — otherwise "slot 0" in a log would mean the phone or the Mac depending on which
        // datagram won a race, and there would be no way to tell which.
        let table = routes();
        table.open(&[CLIENT, HOST]);

        assert_eq!(table.route(&HOST, addr(2, 6000)), Routed::NoPeer);
        assert_eq!(table.route(&CLIENT, addr(1, 5000)), Routed::Peer(addr(2, 6000)));
        assert_eq!(table.route(&HOST, addr(2, 6000)), Routed::Peer(addr(1, 5000)));
    }

    #[test]
    fn an_end_that_moves_takes_its_slot_with_it() {
        // The case the whole address-is-the-binding rule exists for: a carrier NAT moves the
        // phone's mapping mid-session. Its next datagram, from the new address, is the re-bind —
        // there is no second handshake, and no state that has to be replaced carefully. This is the
        // one failure the video path cannot recover from by reconnecting, because datagrams have no
        // connection to re-establish.
        let table = routes();
        table.open(&[CLIENT, HOST]);
        table.route(&CLIENT, addr(1, 5000));
        table.route(&HOST, addr(2, 6000));

        assert_eq!(
            table.route(&CLIENT, addr(1, 7000)),
            Routed::Peer(addr(2, 6000)),
            "same slot, new address, and the peer is still there"
        );
        assert_eq!(
            table.route(&HOST, addr(2, 6000)),
            Routed::Peer(addr(1, 7000)),
            "the host follows the phone to where it moved"
        );
    }

    #[test]
    fn a_token_can_only_move_its_own_slot() {
        // Presenting the Mac's token moves the Mac. It does not let whoever holds it take the
        // client's slot, which one shared token could not have expressed.
        let table = routes();
        table.open(&[CLIENT, HOST]);
        table.route(&CLIENT, addr(1, 5000));
        table.route(&HOST, addr(2, 6000));

        assert_eq!(table.route(&HOST, addr(3, 7000)), Routed::Peer(addr(1, 5000)));
        assert_eq!(table.route(&CLIENT, addr(1, 5000)), Routed::Peer(addr(3, 7000)));
    }

    #[test]
    fn an_address_that_holds_the_other_slot_cannot_claim_this_one() {
        // The one shape of traffic that must not be forwarded. If the Mac's address could claim the
        // phone's slot, the relay would send the Mac's datagrams to the Mac: a reflection, and a
        // stream that never drains. It is also what two ends behind one NAT look like, where every
        // forward would be the same reflection.
        let table = routes();
        table.open(&[CLIENT, HOST]);
        table.route(&CLIENT, addr(1, 5000));
        table.route(&HOST, addr(2, 6000));

        assert_eq!(
            table.route(&CLIENT, addr(2, 6000)),
            Routed::Dropped,
            "the Mac's address cannot claim the phone's slot"
        );

        // And nothing moved while it tried: both ends are exactly where they were.
        assert_eq!(table.route(&CLIENT, addr(1, 5000)), Routed::Peer(addr(2, 6000)));
        assert_eq!(table.route(&HOST, addr(2, 6000)), Routed::Peer(addr(1, 5000)));
    }

    #[test]
    fn a_token_that_was_never_issued_routes_nothing() {
        let table = routes();
        table.open(&[CLIENT, HOST]);

        assert_eq!(table.route(&token(9), addr(1, 5000)), Routed::Dropped);
        assert_eq!(table.route(&CLIENT, addr(1, 5000)), Routed::NoPeer);
        assert_eq!(table.route(&token(9), addr(1, 5000)), Routed::Dropped);
    }

    #[test]
    fn a_bound_end_with_no_peer_yet_has_nowhere_to_send() {
        // What the second end's arrival changes. Not an error, and not a drop: the session is fine
        // and the frames that arrive before its other half has spoken are simply early.
        let table = routes();
        table.open(&[CLIENT, HOST]);

        assert_eq!(table.route(&CLIENT, addr(1, 5000)), Routed::NoPeer);
        assert_eq!(table.route(&HOST, addr(2, 6000)), Routed::Peer(addr(1, 5000)));
    }

    #[test]
    fn many_sessions_share_the_table_without_crossing() {
        // The property the shared socket is for: one table holds them all, and a token finds its
        // own session and nobody else's. Twenty is arbitrary; what it catches is a lookup that
        // would have been right with one session in the table and wrong with two.
        let table = routes();
        const SESSIONS: u8 = 20;

        for n in 0..SESSIONS {
            table.open(&[token(n * 2 + 1), token(n * 2 + 2)]);
        }
        assert_eq!(table.len(), SESSIONS as usize);

        for n in 0..SESSIONS {
            let client = token(n * 2 + 1);
            let host = token(n * 2 + 2);
            let client_addr = addr(10, 5000 + u16::from(n));
            let host_addr = addr(11, 6000 + u16::from(n));

            assert_eq!(table.route(&host, host_addr), Routed::NoPeer);
            assert_eq!(
                table.route(&client, client_addr),
                Routed::Peer(host_addr),
                "session {n} must find its own host"
            );
            assert_eq!(
                table.route(&host, host_addr),
                Routed::Peer(client_addr),
                "and back, to its own client"
            );
        }
    }

    #[test]
    fn closing_a_session_retires_both_of_its_tokens() {
        let table = routes();
        table.open(&[CLIENT, HOST]);
        table.route(&CLIENT, addr(1, 5000));
        assert_eq!(table.len(), 1);

        table.close(&[CLIENT, HOST]);

        assert_eq!(table.len(), 0);
        assert_eq!(table.route(&CLIENT, addr(1, 5000)), Routed::Dropped);
        assert_eq!(table.route(&HOST, addr(2, 6000)), Routed::Dropped);
    }

    #[test]
    fn reaping_takes_a_whole_session_and_leaves_a_silent_neighbour() {
        let table = routes();
        table.open(&[CLIENT, HOST]);
        table.open(&[token(3), token(4)]);
        table.route(&CLIENT, addr(1, 5000));
        table.route(&HOST, addr(2, 6000));

        // `Duration::ZERO` is "longer than any silence": every session that has a clock goes, and a
        // session with no clock at all cannot be reached by any timeout. That is the whole rule in
        // one call, with no sleeping and so no flake.
        assert_eq!(table.reap(Duration::ZERO), 1);
        assert_eq!(table.len(), 1, "the session that has not spoken is still there");

        // Both halves of the reaped session went, not just the one that happened to be looked at
        // first: a route left behind forwards for an end that no longer has a peer.
        assert_eq!(table.route(&CLIENT, addr(1, 5000)), Routed::Dropped);
        assert_eq!(table.route(&HOST, addr(2, 6000)), Routed::Dropped);

        // And the neighbour is untouched, binds, and has nowhere to send yet.
        assert_eq!(table.route(&token(3), addr(3, 7000)), Routed::NoPeer);
    }

    #[test]
    fn a_session_that_never_spoke_is_not_expired_by_the_video_clock() {
        // Unstarted, not idle. The registry's own sweep ends sessions that were never used; a
        // timeout here would take a session's routes away while its two ends are still connecting,
        // which is the ordinary state of every session for the first second of its life.
        let table = routes();
        table.open(&[CLIENT, HOST]);

        assert_eq!(table.reap(Duration::ZERO), 0);
        assert_eq!(table.len(), 1, "still open for business");
        assert_eq!(table.route(&CLIENT, addr(1, 5000)), Routed::NoPeer);
    }

    /// A timed test, deliberately: the one property here that is about the clock rather than about
    /// the table, and the one a client's keepalive timer exists for. The margins are wide — eight
    /// keepalives' worth of slack against the timeout — so a busy machine slows the test down
    /// rather than failing it.
    #[tokio::test]
    async fn a_repeated_bare_token_keeps_a_session_off_the_clock() {
        // What a bare-token keepalive buys. A NAT mapping that expires is a session that silently
        // stops receiving video, so a client re-sends its token on a timer; what that has to do
        // here is hold the session open while it is plainly still there — and note that the Mac
        // says nothing at all for the whole of it, which is what a screen that has not changed
        // looks like.
        let ttl = Duration::from_millis(400);
        let table = routes();
        table.open(&[CLIENT, HOST]);
        assert_eq!(table.route(&CLIENT, addr(1, 5000)), Routed::NoPeer);
        assert_eq!(table.route(&HOST, addr(2, 6000)), Routed::Peer(addr(1, 5000)));

        for _ in 0..6 {
            tokio::time::sleep(Duration::from_millis(50)).await;
            assert_eq!(
                table.route(&CLIENT, addr(1, 5000)),
                Routed::Peer(addr(2, 6000)),
                "a bare token is accepted and refreshes the route"
            );
        }

        assert_eq!(
            table.reap(ttl),
            0,
            "six of the timeouts have passed since the session started, and it is still talking"
        );

        tokio::time::sleep(ttl * 2).await;
        assert_eq!(table.reap(ttl), 1, "once the keepalives stop, the session goes");
    }

    #[tokio::test]
    async fn allocate_hands_out_distinct_tokens() {
        let registry = Registry::new(usize::MAX);
        let (_quota, account) = client_account();
        let a = registry.allocate("mac", "phone", account.clone()).await.expect("room for a session");
        let b = registry.allocate("mac", "other-phone", account).await.expect("room for a session");

        assert_ne!(a.control_token, b.control_token);
        assert_ne!(a.video_tokens, b.video_tokens);
        // And the two ends of one session do not share theirs either. That is what makes a re-bind
        // unambiguous, and it is why the two `SessionReady` messages differ.
        assert_ne!(a.video_tokens[CLIENT_SLOT], a.video_tokens[HOST_SLOT]);
        assert_eq!(registry.len().await, 2);
    }

    #[tokio::test]
    async fn reallocating_for_the_same_pair_supersedes_the_old_session() {
        let registry = Registry::new(usize::MAX);
        let (_quota, account) = client_account();
        let first = registry.allocate("mac", "phone", account.clone()).await.expect("room for a session");
        let second = registry.allocate("mac", "phone", account).await.expect("room for a session");

        assert_eq!(registry.len().await, 1, "one phone, one Mac, one session");
        assert!(registry.video_token_for(&first.control_token).await.is_none());
        assert!(registry.video_token_for(&second.control_token).await.is_some());

        // And the superseded session's video routes went with it. This is the teardown that has to
        // happen *while the relay is still running*, which is the difference the shared table makes:
        // there is no socket closing behind a superseded session to make forgetting it harmless.
        assert_eq!(
            registry.routes().route(&first.video_tokens[CLIENT_SLOT], addr(1, 5000)),
            Routed::Dropped
        );
        assert_ne!(
            registry.routes().route(&second.video_tokens[CLIENT_SLOT], addr(1, 5000)),
            Routed::Dropped,
            "the replacement's tokens are the ones that route now"
        );
    }

    #[tokio::test]
    async fn a_released_session_leaves_nothing_routable_behind() {
        let registry = Registry::new(usize::MAX);
        let (_quota, account) = client_account();
        let allocated = registry.allocate("mac", "phone", account).await.expect("room for a session");
        let [client, host] = allocated.video_tokens;

        registry.release(&allocated.control_token).await;

        assert_eq!(registry.routes().route(&client, addr(1, 5000)), Routed::Dropped);
        assert_eq!(registry.routes().route(&host, addr(2, 6000)), Routed::Dropped);
        assert!(registry.routes().is_empty());
    }

    #[tokio::test]
    async fn the_sweep_retires_the_video_routes_of_what_it_sweeps() {
        // The path that ends the sessions nobody asked to end: a phone that crashed, a Mac that was
        // unplugged. What it must not leave behind is a token that still forwards.
        let registry = Registry::new(usize::MAX);
        let (_quota, account) = client_account();
        let allocated = registry.allocate("mac", "phone", account).await.expect("room for a session");
        let [client, host] = allocated.video_tokens;
        assert_eq!(registry.routes().len(), 1);

        assert_eq!(registry.sweep(Duration::ZERO).await, 1);

        assert_eq!(registry.routes().route(&client, addr(1, 5000)), Routed::Dropped);
        assert_eq!(registry.routes().route(&host, addr(2, 6000)), Routed::Dropped);
        assert!(registry.routes().is_empty());
    }

    /// **The regression, at the size it actually happened.** A session whose splice is running is
    /// not an abandoned session, however long it has been open: the sweep used to judge it by a
    /// clock only `join_control` ever wound, so every relayed session lost its video at the TTL
    /// while its control connection kept carrying.
    #[tokio::test]
    async fn a_running_splice_is_not_swept_however_long_it_has_been_open() {
        let registry = Registry::new(usize::MAX);
        let (_quota, account) = client_account();
        let allocated = registry.allocate("mac", "phone", account).await.expect("room for a session");
        let [client, _host] = allocated.video_tokens;

        // A TTL far shorter than a real one, so that a session which has been running for longer
        // than the TTL can be tested in a test's own lifetime. What matters is the relation, not
        // the number: every sweep below is told the session is older than this.
        let ttl = Duration::from_millis(60);

        // Each round waits past the TTL with nothing happening but the splice's own tick, which is
        // what a session being used looks like from the registry's side.
        for round in 0..3 {
            tokio::time::sleep(Duration::from_millis(20)).await;
            registry.touch(&allocated.control_token).await;
            assert_eq!(registry.sweep(ttl).await, 0, "round {}: a live splice was swept", round);
        }

        // And the routes it was holding are still there, which is the part a user notices: the
        // picture stopping while the control connection carries on is what the sweep cost.
        assert_ne!(registry.routes().route(&client, addr(1, 5000)), Routed::Dropped);
        assert_eq!(registry.routes().len(), 1);

        // The contrast, without which the loop above would pass on a TTL that could never sweep
        // anything: left alone, this same session goes, and takes its routes with it.
        tokio::time::sleep(Duration::from_millis(80)).await;
        assert_eq!(registry.sweep(ttl).await, 1);
        assert!(registry.routes().is_empty());
    }

    #[tokio::test]
    async fn the_first_connection_waits_and_the_second_hands_itself_over() {
        let registry = Registry::new(usize::MAX);
        let (_quota, account) = client_account();
        let allocated = registry.allocate("mac", "phone", account).await.expect("room for a session");
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

    /// **The token is spent once both ends have used it.** It used to be reusable for the whole
    /// life of the session, because the waiting slot empties as soon as a pair is joined and
    /// nothing else recorded that it had been: a third presentation became a fresh waiter and a
    /// fourth was spliced to it. Whoever learned a token could therefore stand in for a real end
    /// and have a second splice charged to that session's account.
    #[tokio::test]
    async fn a_token_that_has_been_used_by_both_ends_joins_nothing_more() {
        let registry = Registry::new(usize::MAX);
        let (_quota, account) = client_account();
        let allocated = registry.allocate("mac", "phone", account).await.expect("room for a session");
        let token = allocated.control_token;

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let first = registry
            .join_control(&token, TcpStream::connect(addr).await.unwrap())
            .await
            .expect("the first presentation is the one that waits");
        assert!(matches!(
            registry
                .join_control(&token, TcpStream::connect(addr).await.unwrap())
                .await,
            Some(Join::HandedOver)
        ));

        assert!(
            registry
                .join_control(&token, TcpStream::connect(addr).await.unwrap())
                .await
                .is_none(),
            "a third presentation is refused rather than becoming a new waiter"
        );

        // And the session is otherwise unharmed: the pair that arrived first still has both halves.
        let Join::Waiting { mine, peer } = first else {
            panic!("the first connection should be the one waiting");
        };
        assert!(mine.peer_addr().is_ok());
        assert!(peer.await.is_ok());
    }

    #[tokio::test]
    async fn a_token_that_was_never_issued_joins_nothing() {
        let registry = Registry::new(usize::MAX);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let socket = TcpStream::connect(listener.local_addr().unwrap()).await.unwrap();

        assert!(registry.join_control(&[0xff; 16], socket).await.is_none());
    }

    #[tokio::test]
    async fn releasing_a_session_makes_its_token_useless() {
        let registry = Registry::new(usize::MAX);
        let (_quota, account) = client_account();
        let allocated = registry.allocate("mac", "phone", account).await.expect("room for a session");
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
        let registry = Registry::new(usize::MAX);
        let (_quota, account) = client_account();
        registry.allocate("mac", "phone", account).await.expect("room for a session");

        assert_eq!(registry.sweep(Duration::from_secs(300)).await, 0);
        assert_eq!(registry.sweep(Duration::ZERO).await, 1);
        assert!(registry.is_empty().await);
    }
}
