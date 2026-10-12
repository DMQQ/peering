//! Relay-time quota: how much relay a client gets is decided by the plan it is metered on. Free is
//! the smallest allowance, the cheapest subscription is larger, and the two above that are not
//! metered at all.
//!
//! **A session is charged while it runs, not when it ends.** The check before a session is
//! allocated is one half of the enforcement and it is not enough on its own, because it reads a
//! counter that only moves when a splice finishes: a client with one second of allowance left
//! could open a splice and hold it open for a week. So `tcp_relay` charges the counter on a timer
//! for as long as the splice is alive, through the [`Meter`] below, and ends the session once the
//! plan's allowance for the window is gone. Paid keys and the two unlimited plans are charged the
//! same way and are never ended by it: their usage is recorded, it just does not bound anything.
//!
//! **A day, not a month.** The window is deliberately short. An allowance of half an hour a day is
//! something a person can plan around — connect now, or wait until tomorrow — where a monthly
//! pot is either unspent or gone, and the failure mode of "gone" is a paywall in front of
//! someone who has only just worked out that the relay is the point. Thirty times half an hour is
//! more time than the three hours a month it replaced, and it is spread the way the use is.
//!
//! **The counter is written down**, in an append-only log at `PEERINGD_USAGE_LOG`. It used to
//! live only in a HashMap for the lifetime of the process, which meant `Restart=always` was an
//! unlimited relay: a crash loop, a deploy, or an operator's `systemctl restart` handed every
//! client the full allowance again. What that costs is bandwidth rather than money, and bandwidth
//! is the thing being sold, so it is worth a file.
//!
//! **A log rather than a database**, and the shape of the data is what decides it: one line per
//! charge, which is one for a session that ran to the end of a period and one per period for a
//! session that is still running, and a question that is only ever "how many seconds has this
//! client spent in this window". A database buys atomic updates and queries, and neither is wanted;
//! the only thing it would replace is the full rewrite that compaction does, and at this size that
//! rewrite is cheaper than the dependency.
//!
//! Setting the path is the operator's business, and leaving it unset is legal: the relay runs
//! with the counter in memory and says so at startup. A default path would be a relay that looks
//! healthy and silently records nothing, which is worse than one that admits it.
//!
//! **Where the plan comes from is `storekit`'s business, not this module's.** A client that sends
//! the receipt Apple signed for its purchase is metered by the product that receipt names, and a
//! client that sends nothing, or nothing that verifies, is metered as free unless an operator has
//! turned `PEERINGD_TRUST_CLAIMED_PLANS` on, which `storekit` carries the reasoning for. What
//! matters here is only that a `Plan` arrives having already been decided: this module never reads
//! a string a client sent, and there is no spelling of "unlimited" it can be handed by accident.
//!
//! **The counter is keyed by an identity, and since the client proof shipped it is a key rather
//! than a name.** An app announces a device id it made up and keeps in its own storage, so
//! reinstalling it produced a new id and a fresh allowance, so the free tier could be renewed by
//! deleting the app. A client that signs its request is metered under the public half of the key it
//! signed with, and that key is in the Keychain, which iOS keeps through a reinstall. A client that
//! sends no proof is metered by its announced id, which is every build before this one and remains
//! the fallback here: see `device_proof::client_payload`, and `signalling` for where the choice is
//! made.
//!
//! What a false plan does not buy: the relay's metering is about bandwidth, not access. A Mac is
//! reached by passing its own pairing handshake, which this process cannot forge or skip, so a
//! client that lies about its plan gets free relay time and nothing else. It is also strictly
//! better than what this replaced, where a paying subscriber's self-minted key matched nothing on
//! the server and they were metered exactly like a free client.
//!
//! **API keys are not credentials.** They gate relay access, but the actual privacy guarantee
//! (end-to-end encryption) holds regardless. A leaked key lets someone use the relay for free;
//! it does not let them read anyone's screen. They are also the one grant here that the server
//! holds rather than the client asserting, which is why the check is kept even though nothing
//! mints a key that could be in the set — see `PEERINGD_PAID_KEYS` in the README.

use std::collections::{HashMap, HashSet};
use std::io;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use tracing::warn;

use crate::config::PlanAllowances;
use crate::referrals::{ReferralTerms, Referrals};
use crate::stats::PlanTier;
use crate::usage_log::{Totals, UsageLogWriter, WindowUsage};

/// One-day rolling window. Dividing epoch seconds by this gives a bucket number that advances
/// every 24 hours — no calendar library needed, and the exact hour it rolls over does not matter
/// to the quota. It does matter to the clock the app shows, which mirrors this arithmetic rather
/// than a calendar day so that the bar and the meter turn over together.
const WINDOW_SECS: u64 = 24 * 3600;

fn window_key() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        / WINDOW_SECS
}

/// The plan a client is on: either the one a receipt proved or the one it claimed, decided in
/// `storekit` before anything here sees it.
///
/// `Plus` and `Pro` are separate cases even though they are metered identically, because the log
/// line an operator reads should say which product was bought or claimed rather than flattening
/// the two.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Plan {
    Free,
    Relay,
    Plus,
    Pro,
}

impl Plan {
    /// Reads the plan a client claims in the handshake, leniently and in one direction only.
    ///
    /// **Nothing that is not exactly a known name can mean unlimited.** Absent, empty, misspelled,
    /// shouted, padded with spaces, or not a string at all — every one of those is `Free`, which is
    /// the smallest allowance rather than a refusal. Leniency is the safe direction here: a client
    /// this does not understand gets metered, and a future plan name added to the app will be
    /// metered as free by this relay until this relay knows it, rather than refused or trusted.
    ///
    /// Whitespace and case are forgiven because they cannot be a lie, only a mistake, and a paying
    /// subscriber metered as free is the exact failure this whole change exists to remove.
    ///
    /// This is the *claim*. Whether it decides anything is `storekit`'s call, and the answer for a
    /// client with a receipt that verifies is that it does not.
    pub fn from_wire(raw: Option<&str>) -> Self {
        match raw.map(str::trim).map(str::to_ascii_lowercase).as_deref() {
            Some("relay") => Self::Relay,
            Some("plus") => Self::Plus,
            Some("pro") => Self::Pro,
            _ => Self::Free,
        }
    }

    /// The wire name, for logs. Deliberately the same vocabulary the client sends, so that a log
    /// line and a packet can be read side by side.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Free => "free",
            Self::Relay => "relay",
            Self::Plus => "plus",
            Self::Pro => "pro",
        }
    }
}

/// How often a splice that is under way is charged for the time it has run.
///
/// **This is the number that bounds what a session can overrun its allowance by.** Charging only at
/// the end of a splice meant the check before a session was allocated was the only check there was,
/// so a client with a second of credit could hold a connection open for as long as it liked. With
/// the counter charged on this timer, the worst case is one period of relay a client was not
/// entitled to.
///
/// Fifteen seconds is a compromise between two costs rather than a round number. Every charge is a
/// line appended and fsynced to the usage log, so a shorter period writes more of them, and a
/// longer one lets a session run on further past the moment its allowance was gone. Against
/// allowances measured in minutes, either error is small.
pub const CHARGE_PERIOD: Duration = Duration::from_secs(15);

pub struct QuotaTracker {
    allowances: PlanAllowances,
    /// How often a running splice is charged. See [`CHARGE_PERIOD`].
    charge_period: Duration,
    /// Extra free time earned by invites. Added to the free allowance only, so it can never turn a
    /// paid plan's "unlimited" into a number.
    referrals: Arc<Referrals>,
    inner: Mutex<Inner>,
}

struct Inner {
    usage: Totals,
    paid_keys: HashSet<String>,
    /// Absent when no path was configured or the file would not open. See ``with_usage_log``.
    log: Option<UsageLogWriter>,
    /// Whether the writer's queue was full at the last charge, so the warning is once per episode.
    log_backlogged: bool,
    /// Whether the last thing that happened to the map was an eviction.
    ///
    /// A flag rather than a count of evictions, because this exists to make one log line per
    /// episode rather than one per evicted client: an attacker inventing ids would otherwise write
    /// a warning into the journal at the same rate that they are writing usage lines into the file.
    evicting: bool,
}

/// How many clients the counter will track at once.
///
/// **A bound that does not depend on what a peer chooses to send.** A client id is a string of up to
/// 256 bytes that the client invents, and every one of them gets an entry in the map above and a
/// line in the file below, so without a ceiling the memory and the disk both grow with the number
/// of ids somebody has spent a second of relay time under. Twenty thousand is far past what this
/// relay will see in a day for a long time; the number is here so that the answer to "how big can
/// this get" is a constant rather than a peer's patience.
///
/// **What eviction costs, said plainly:** a client whose entry is dropped starts its window again,
/// so an attacker can churn ids to keep giving themselves fresh allowances. That is not a new hole
/// and this ceiling does not close it: a *new* id always starts at zero whatever this is set to,
/// which is the reinstall hole written down in the README. What it bounds is memory and disk, and
/// the client that loses its entry is as likely to be a real one as an invented one.
const MAX_TRACKED_CLIENTS: usize = 20_000;

impl QuotaTracker {
    /// A tracker whose counter lives only as long as the process does.
    ///
    /// Used by the tests, and by a deployment that has not configured ``PEERINGD_USAGE_LOG``.
    pub fn new(allowances: PlanAllowances, paid_keys: HashSet<String>) -> Self {
        Self {
            allowances,
            charge_period: CHARGE_PERIOD,
            referrals: Arc::new(Referrals::in_memory(ReferralTerms::default())),
            inner: Mutex::new(Inner {
                usage: HashMap::new(),
                paid_keys,
                log: None,
                log_backlogged: false,
                evicting: false,
            }),
        }
    }

    /// The same tracker, charging a running splice every `period` instead of every
    /// [`CHARGE_PERIOD`].
    ///
    /// **For the tests**, which cannot wait fifteen seconds to watch a meter charge twice, and it
    /// takes `self` and hands it back rather than being a third constructor because the period is
    /// the only thing any caller has ever wanted to change about one.
    pub fn with_charge_period(mut self, period: Duration) -> Self {
        self.charge_period = period;
        self
    }

    /// The same tracker, with invite bonuses read from `referrals`.
    pub fn with_referrals(mut self, referrals: Arc<Referrals>) -> Self {
        self.referrals = referrals;
        self
    }

    pub fn referrals(&self) -> &Arc<Referrals> {
        &self.referrals
    }

    /// A tracker whose counter is kept in a file, or one that explains why it is not.
    ///
    /// **Returns a working tracker either way.** A log that will not open is a relay that gives
    /// away relay time, and refusing to start over it would be a relay that is down instead, which
    /// is a much worse trade. The error comes back beside the tracker so that `main` can say so at
    /// startup, where the operator will see it.
    pub fn with_usage_log(
        allowances: PlanAllowances,
        paid_keys: HashSet<String>,
        path: Option<PathBuf>,
    ) -> (Self, Option<io::Error>) {
        let (log, usage, failure) = match path {
            Some(path) => match UsageLogWriter::open(path, window_key()) {
                Ok((log, usage)) => (Some(log), usage, None),
                Err(error) => (None, HashMap::new(), Some(error)),
            },
            None => (None, HashMap::new(), None),
        };

        let tracker = Self {
            allowances,
            charge_period: CHARGE_PERIOD,
            referrals: Arc::new(Referrals::in_memory(ReferralTerms::default())),
            inner: Mutex::new(Inner {
                usage,
                paid_keys,
                log,
                log_backlogged: false,
                evicting: false,
            }),
        };
        (tracker, failure)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn is_paid(&self, api_key: Option<&str>) -> bool {
        let Some(key) = api_key else { return false };
        self.lock().paid_keys.contains(key)
    }

    /// What this plan is allowed in one window. `None` is unlimited.
    fn allowance(&self, plan: Plan) -> Option<u64> {
        match plan {
            Plan::Free => self.allowances.free_seconds,
            Plan::Relay | Plan::Plus | Plan::Pro => None,
        }
    }

    /// Remaining seconds this window. `None` means the quota does not apply to this client, either
    /// because they hold a valid paid key or because the plan they stated has no limit.
    ///
    /// **Usage is not per plan.** The counter is relay time spent in this window and the allowance
    /// is what the plan permits, so a client that spends twenty minutes on free and then subscribes
    /// keeps that usage in the log after subscribing. Paid plans are unlimited, so the counter no
    /// longer bounds the session. That is also what makes an upgrade take effect mid-window with no
    /// state to migrate.
    pub fn remaining(&self, client_id: &str, api_key: Option<&str>, plan: Plan) -> Option<u64> {
        if self.is_paid(api_key) {
            return None;
        }
        let allowance = self.allowance(plan)?;
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
        let allowance = allowance.saturating_add(self.referrals.bonus_seconds(client_id, now));

        let inner = self.lock();
        let window = window_key();
        let used = inner
            .usage
            .get(client_id)
            .filter(|usage| usage.window == window)
            .map(|usage| usage.seconds)
            .unwrap_or(0);
        Some(allowance.saturating_sub(used))
    }

    /// The terms a splice that is about to be allocated will be charged on.
    ///
    /// **The plan and the key are taken here and belong to the session for its life.** A client
    /// that buys something mid-session is metered by it from the next session on, which is the same
    /// answer [`remaining`](Self::remaining) gives at the moment this one is handed out, and a
    /// splice that read the plan again at every charge would let a client change its own terms
    /// halfway through. What is *not* fixed here is the count left: that belongs to the counter, it
    /// moves while the splice runs, and reading it live is the whole point of the meter.
    pub fn account(
        self: &Arc<Self>,
        client_id: &str,
        api_key: Option<&str>,
        plan: Plan,
    ) -> Account {
        Account {
            client_id: client_id.to_string(),
            plan,
            api_key: api_key.map(str::to_string),
            tracker: Arc::clone(self),
        }
    }

    /// Adds relay time to a client's counter, a piece at a time.
    ///
    /// Called by a [`Meter`] as a splice runs and once more when it ends, so the deduction is real
    /// usage rather than an estimate made at session start. Each call adds what it is given to the
    /// client's total for the current window and appends that many seconds to the log, which is why
    /// the meter hands over only the seconds that have not been charged yet: two calls that each
    /// added a session's whole duration would bill it twice.
    ///
    /// A minimum of one second is charged even for the shortest splice, so a client cannot run a
    /// large number of sub-second sessions to stay under the counter. The floor belongs to the
    /// meter, which applies it to the splice rather than to each call, and it is repeated here as
    /// the backstop for every other caller.
    pub fn record(&self, client_id: &str, duration: Duration) {
        let secs = duration.as_secs().max(1);
        let mut inner = self.lock();
        let window = window_key();
        let entry = inner.usage.entry(client_id.to_string()).or_insert(WindowUsage { window, seconds: 0 });
        if entry.window != window {
            *entry = WindowUsage { window, seconds: 0 };
        }
        entry.seconds = entry.seconds.saturating_add(secs);

        let Inner { usage, log, log_backlogged, evicting, .. } = &mut *inner;

        if usage.len() > MAX_TRACKED_CLIENTS {
            Self::evict(usage, window, client_id, evicting);
        } else if *evicting {
            // Back under the ceiling, so the next episode is worth a line of its own.
            *evicting = false;
        }

        // Queued to the log's writer thread, which batches the writes and does the `fsync`, so a
        // slow disk never holds this lock. The map stays the truth for this run either way; a
        // charge the file misses only costs a little after the next restart.
        let Some(log) = log.as_ref() else { return };
        let queued = log.charge(client_id, window, secs);
        if !queued && !*log_backlogged {
            warn!("the usage log writer is falling behind; charges are counted but not written until it catches up");
        }
        *log_backlogged = !queued;
    }

    /// Waits until every charge made so far has been handed to the disk. For shutdown and tests;
    /// the metering path never waits.
    pub fn flush(&self) {
        let flusher = self.lock().log.as_ref().map(UsageLogWriter::flusher);
        if let Some(flusher) = flusher {
            flusher.flush();
        }
    }

    /// Makes room in the counter when it is full.
    ///
    /// **Entries from another window go first**, because they are already dead: nothing reads them,
    /// and `record` would overwrite them in place the moment their client came back. Only if that
    /// is not enough does it start dropping entries that belong to the current window, which is the
    /// case where a client genuinely loses its counter and starts its day again.
    ///
    /// Arbitrary rather than oldest-first, because a `HashMap` does not know which entry is oldest
    /// and giving it an order would cost a second structure to maintain on the hot path of every
    /// charge. The choice changes which client is unlucky, not how much is forgotten.
    fn evict(
        usage: &mut Totals,
        window: u64,
        keep: &str,
        evicting: &mut bool,
    ) {
        usage.retain(|_, entry| entry.window == window);
        let was = usage.len();
        if was > MAX_TRACKED_CLIENTS {
            let overflow = was - MAX_TRACKED_CLIENTS;
            // `keep` is the client whose charge is being recorded right now. Dropping that one
            // would throw away the seconds in this very call, which is the one entry we know for
            // certain somebody is waiting on.
            let doomed: Vec<String> = usage
                .keys()
                .filter(|key| key.as_str() != keep)
                .take(overflow)
                .cloned()
                .collect();
            for key in doomed {
                usage.remove(&key);
            }
        }
        // Once per episode: see the field's own note for why this is a flag and not a counter.
        if !*evicting {
            *evicting = true;
            warn!(
                tracked = usage.len(),
                limit = MAX_TRACKED_CLIENTS,
                "the relay-time counter is full; clients dropped here start their window again"
            );
        }
    }
}

/// What a session will be charged to, and on what terms.
///
/// **Built when a session is allocated and carried by it**, because the splice starts somewhere
/// else entirely: `tcp_relay` holds a control token and two sockets, and needs to know whose
/// allowance to spend and which plan's number bounds it. Whoever resolves the plan, which is
/// `signalling` and `storekit`, has both in hand at the moment the session is handed out, and this
/// is what travels to the splice from there. See [`QuotaTracker::account`].
#[derive(Clone)]
pub struct Account {
    client_id: String,
    plan: Plan,
    /// The key the client presented, if it presented one. Kept rather than read once into a
    /// boolean, so that every question about this session is answered by
    /// [`QuotaTracker::remaining`] and there is one place that decides what a paid key is worth.
    api_key: Option<String>,
    tracker: Arc<QuotaTracker>,
}

impl Account {
    /// The meter for a splice that is starting now.
    ///
    /// **The clock starts here rather than at allocation, and the difference is not small.** A
    /// session is allocated when the phone asks for a Mac, and its two ends can take seconds to
    /// turn up; a meter that ran from allocation would charge for the waiting. What is being paid
    /// for is the splice.
    pub fn start(self) -> Meter {
        Meter {
            account: self,
            started: Instant::now(),
            recorded: 0,
            ceiling: None,
        }
    }
}

/// One splice, as the counter sees it: what it owes so far, and whether its plan has anything left.
///
/// Driven by `tcp_relay`, which calls [`charge`](Self::charge) on a timer for as long as the splice
/// runs and ends the session when the answer is zero.
pub struct Meter {
    account: Account,
    /// When the splice began, which is when this was built. See [`Account::start`].
    started: Instant,
    /// Whole seconds already written down for this splice. What the next charge has to add is the
    /// difference between this and the splice's own run, which is what makes charging twice
    /// harmless. See [`charge`](Self::charge).
    recorded: u64,
    /// Time after which this splice is no longer charged, once it has been found idle. See
    /// [`stop_at`](Self::stop_at).
    ceiling: Option<Instant>,
}

impl Meter {
    /// How often this meter wants charging, which is the tracker's own period unless a test said
    /// otherwise.
    pub fn period(&self) -> Duration {
        self.account.tracker.charge_period
    }

    /// Moves this meter's clock back, so a test can charge for an hour of splice without waiting
    /// for one. It is the only part of this type a test needs to reach, and the alternative to it
    /// is a suite that sleeps.
    #[cfg(test)]
    fn backdate(&mut self, by: Duration) {
        self.started -= by;
    }

    /// Free when the plan has an allowance, paid for a purchased plan, and unlimited for anything
    /// else the counter does not bound (a paid key). Named for the journal, never for billing.
    pub fn tier(&self) -> PlanTier {
        if self.remaining().is_some() {
            PlanTier::Free
        } else if self.account.plan == Plan::Free {
            PlanTier::Unlimited
        } else {
            PlanTier::Paid
        }
    }

    /// The client this splice is metered against, for the line that says a session was cut off.
    pub fn client_id(&self) -> &str {
        &self.account.client_id
    }

    /// Records what this splice owes, and reports what it has left. `None` means the counter does
    /// not bound it: a paid key, or a plan with no limit, neither of which is ever ended by this.
    ///
    /// **Incremental and cumulative at once**, which is what makes it safe to call on a timer, once
    /// more when the splice ends, and again from the drop below. What the counter is handed is the
    /// difference between the seconds this splice has now run for and the seconds it has already
    /// been charged for, so:
    ///
    /// * the sum of every call is the splice's own duration, and no second is counted twice;
    /// * a call that finds no whole second has passed since the last one writes nothing at all,
    ///   which is what stops a short period turning into one line per tick in the usage log;
    /// * a splice that ran for a fraction of a second still costs one, because the run is floored
    ///   at a second. That is the rule that stops a client running thousands of sub-second sessions
    ///   to stay under a counter that rounds down, and it belongs to the splice rather than to the
    ///   call: the floor is on the running total, not on each piece of it.
    pub fn charge(&mut self) -> Option<u64> {
        self.charge_through(Instant::now())
    }

    /// [`charge`](Self::charge), counting the splice's run only up to `until`: the last moment bytes
    /// crossed, so that a connection that has stalled is not billed for the stall. Never counts past
    /// the ceiling [`stop_at`](Self::stop_at) set, nor past now.
    pub fn charge_through(&mut self, until: Instant) -> Option<u64> {
        let until = self.ceiling.map_or(until, |ceiling| ceiling.min(until)).min(Instant::now());
        let run = until.saturating_duration_since(self.started).as_secs().max(1);
        let owed = run.saturating_sub(self.recorded);
        if owed > 0 {
            self.recorded = run;
            self.account
                .tracker
                .record(&self.account.client_id, Duration::from_secs(owed));
        }
        self.remaining()
    }

    /// Ends the splice's billable time at `at` for good, including for the charge a drop makes.
    pub fn stop_at(&mut self, at: Instant) {
        self.ceiling = Some(at);
    }

    /// What this splice has left of its allowance, read from the counter rather than kept here.
    ///
    /// Reading it instead of counting down is what keeps the answer the same as the one the next
    /// `ConnectToHost` will get, including the case where another session for the same client is
    /// spending the same allowance at the same time.
    pub fn remaining(&self) -> Option<u64> {
        self.account.tracker.remaining(
            &self.account.client_id,
            self.account.api_key.as_deref(),
            self.account.plan,
        )
    }
}

impl Drop for Meter {
    /// The charge a cancelled splice would otherwise not pay.
    ///
    /// The ordinary paths charge before they return, and this finds nothing left to add when they
    /// do. This is for the path that has no chance to: a task dropped under a running splice, which
    /// is what a relay shutting down looks like from here, and which would otherwise lose up to one
    /// [`CHARGE_PERIOD`] of a client's usage, in the client's favour. Charging is cumulative, so
    /// running it in both places cannot bill anything twice.
    fn drop(&mut self) {
        self.charge();
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    /// Small fixture allowances for quota arithmetic. These are deliberately not product defaults.
    fn tracker(free_minutes: u64, relay_minutes: u64) -> QuotaTracker {
        QuotaTracker::new(
            PlanAllowances {
                free_seconds: Some(free_minutes * 60),
                relay_seconds: Some(relay_minutes * 60),
            },
            HashSet::new(),
        )
    }

    fn default_tracker() -> QuotaTracker {
        tracker(15, 180)
    }

    #[test]
    fn a_fresh_client_has_the_full_allowance() {
        let q = default_tracker();
        assert_eq!(q.remaining("phone", None, Plan::Free), Some(900));
    }

    #[test]
    fn usage_reduces_the_remaining_time() {
        let q = default_tracker();
        q.record("phone", Duration::from_secs(300));
        assert_eq!(q.remaining("phone", None, Plan::Free), Some(600));
    }

    #[test]
    fn an_invite_bonus_adds_to_the_free_allowance_only() {
        let referrals = Arc::new(Referrals::in_memory(ReferralTerms::default()));
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
        let code = referrals.standing("owner", now).unwrap().code;
        referrals.redeem("friend", &code, now).unwrap();
        let q = default_tracker().with_referrals(referrals);

        assert_eq!(q.remaining("friend", None, Plan::Free), Some(900 + 1800));
        q.record("friend", Duration::from_secs(1000));
        assert_eq!(q.remaining("friend", None, Plan::Free), Some(1700));
        assert_eq!(q.remaining("stranger", None, Plan::Free), Some(900));
        assert_eq!(q.remaining("friend", None, Plan::Pro), None);
    }

    #[test]
    fn exhausted_quota_clamps_at_zero_not_wraps() {
        let q = default_tracker();
        q.record("phone", Duration::from_secs(1000));
        assert_eq!(q.remaining("phone", None, Plan::Free), Some(0));
    }

    #[test]
    fn a_valid_paid_key_bypasses_the_quota() {
        let mut keys = HashSet::new();
        keys.insert("valid-key".to_string());
        let q = QuotaTracker::new(
            PlanAllowances {
                free_seconds: Some(15 * 60),
                relay_seconds: Some(180 * 60),
            },
            keys,
        );
        q.record("phone", Duration::from_secs(1000));
        assert_eq!(q.remaining("phone", Some("valid-key"), Plan::Free), None);
    }

    #[test]
    fn an_invalid_key_falls_through_to_the_free_quota() {
        let mut keys = HashSet::new();
        keys.insert("real-key".to_string());
        let q = QuotaTracker::new(
            PlanAllowances {
                free_seconds: Some(15 * 60),
                relay_seconds: Some(180 * 60),
            },
            keys,
        );
        q.record("phone", Duration::from_secs(1000));
        assert_eq!(q.remaining("phone", Some("wrong-key"), Plan::Free), Some(0));
        assert_eq!(q.remaining("phone", None, Plan::Free), Some(0));
    }

    #[test]
    fn different_clients_have_independent_quotas() {
        let q = default_tracker();
        q.record("phone-a", Duration::from_secs(500));
        assert_eq!(q.remaining("phone-a", None, Plan::Free), Some(400));
        assert_eq!(q.remaining("phone-b", None, Plan::Free), Some(900));
    }

    #[test]
    fn sub_second_splices_charge_at_least_one_second() {
        let q = default_tracker();
        for _ in 0..900 {
            q.record("phone", Duration::from_millis(1));
        }
        assert_eq!(q.remaining("phone", None, Plan::Free), Some(0));
    }

    // MARK: - Plans

    #[test]
    fn each_plan_gets_its_own_allowance() {
        let q = default_tracker();

        assert_eq!(q.remaining("phone", None, Plan::Free), Some(900));
        assert_eq!(
            q.remaining("phone", None, Plan::Relay),
            None,
            "Relay is unlimited where free is metered"
        );
    }

    #[test]
    fn a_relay_plan_is_not_metered() {
        let q = default_tracker();
        q.record("phone", Duration::from_secs(300));

        assert_eq!(q.remaining("phone", None, Plan::Relay), None);
        assert_eq!(q.remaining("phone", None, Plan::Free), Some(600));
    }

    #[test]
    fn plus_and_pro_are_not_metered() {
        let q = default_tracker();
        q.record("phone", Duration::from_secs(24 * 3600));

        assert_eq!(q.remaining("phone", None, Plan::Plus), None);
        assert_eq!(q.remaining("phone", None, Plan::Pro), None);
    }

    #[test]
    fn an_absent_plan_gets_the_free_allowance_and_never_more() {
        let q = default_tracker();
        q.record("phone", Duration::from_secs(1000));

        assert_eq!(Plan::from_wire(None), Plan::Free);
        assert_eq!(
            q.remaining("phone", None, Plan::from_wire(None)),
            Some(0),
            "a client that says nothing is metered, not trusted"
        );
    }

    #[test]
    fn an_unknown_plan_gets_the_free_allowance() {
        let q = default_tracker();
        q.record("phone", Duration::from_secs(1000));

        assert_eq!(q.remaining("phone", None, Plan::from_wire(Some("enterprise"))), Some(0));
    }

    /// The one property that matters most about the parse: no string a client could send, however
    /// odd, may resolve to an unlimited plan by accident.
    #[test]
    fn nothing_but_a_known_name_reads_as_a_paid_plan() {
        for rubbish in [
            "", " ", "free", "free pro", "pro max", "unlimited", "relay plus", "PRO!", "null",
            "0", "true", "plus.pro", "pro--", "pr o",
        ] {
            let plan = Plan::from_wire(Some(rubbish));
            assert_ne!(plan, Plan::Pro, "{rubbish:?} must not read as Pro");
            assert_ne!(plan, Plan::Plus, "{rubbish:?} must not read as Plus");
        }

        assert_eq!(Plan::from_wire(Some("enterprise")), Plan::Free);
        assert_eq!(Plan::from_wire(Some("relayplus")), Plan::Free, "not a name we issue");
    }

    /// Case and spacing are forgiven, because they cannot be a lie, only a typo — and metering a
    /// paying subscriber as free is the failure this whole module exists to remove.
    #[test]
    fn case_and_surrounding_space_are_forgiven() {
        assert_eq!(Plan::from_wire(Some("relay")), Plan::Relay);
        assert_eq!(Plan::from_wire(Some(" RELAY ")), Plan::Relay);
        assert_eq!(Plan::from_wire(Some("Relay")), Plan::Relay);
        assert_eq!(Plan::from_wire(Some("Plus")), Plan::Plus);
        assert_eq!(Plan::from_wire(Some("PRO")), Plan::Pro);
    }

    #[test]
    fn time_already_used_counts_against_a_plan_bought_later() {
        let q = default_tracker();
        q.record("phone", Duration::from_secs(600));

        // Ten minutes on free, then a subscription: paid plans are unlimited so usage accrued on
        // free does not reduce them.
        assert_eq!(q.remaining("phone", None, Plan::Relay), None);
    }

    // MARK: - The log on disk

    /// A path of its own per test, under the system's temporary directory.
    ///
    /// Named rather than created by a helper crate, because adding a dependency to test one file's
    /// behaviour is the wrong way round: this is four lines and it cannot be the reason a build
    /// fails.
    fn scratch(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("peeringd-quota-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        path.join("usage.log")
    }

    fn paid(keys: HashSet<String>, path: PathBuf) -> QuotaTracker {
        QuotaTracker::with_usage_log(
            PlanAllowances {
                free_seconds: Some(900),
                relay_seconds: Some(10_800),
            },
            keys,
            Some(path),
        )
        .0
    }

    #[test]
    fn usage_survives_a_restart() {
        let path = scratch("restart");

        let first = paid(HashSet::new(), path.clone());
        first.record("phone", Duration::from_secs(300));
        assert_eq!(first.remaining("phone", None, Plan::Free), Some(600));

        // A new tracker over the same file is what a restart is, as far as this module can tell.
        first.flush();
        let second = paid(HashSet::new(), path.clone());
        assert_eq!(
            second.remaining("phone", None, Plan::Free),
            Some(600),
            "the twenty minutes spent before the restart are still spent"
        );

        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_restart_does_not_double_count_what_it_replays() {
        let path = scratch("nodouble");

        let first = paid(HashSet::new(), path.clone());
        first.record("phone", Duration::from_secs(300));
        first.record("phone", Duration::from_secs(200));

        first.flush();
        let second = paid(HashSet::new(), path.clone());
        assert_eq!(second.remaining("phone", None, Plan::Free), Some(400));

        // And recording again on top of the replay adds to the total rather than replacing it.
        second.record("phone", Duration::from_secs(100));
        second.flush();
        let third = paid(HashSet::new(), path.clone());
        assert_eq!(third.remaining("phone", None, Plan::Free), Some(300));

        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    /// The property the whole file exists for: the log is the bound on what a restart gives away.
    #[test]
    fn an_exhausted_client_is_still_exhausted_after_a_restart() {
        let path = scratch("exhausted");

        let first = paid(HashSet::new(), path.clone());
        first.record("phone", Duration::from_secs(1_000));

        first.flush();
        let second = paid(HashSet::new(), path.clone());
        assert_eq!(second.remaining("phone", None, Plan::Free), Some(0));

        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_missing_directory_is_created_rather_than_refused() {
        let path = scratch("mkdir").join("nested").join("usage.log");
        assert!(!path.parent().unwrap().exists());

        let (tracker, failure) = QuotaTracker::with_usage_log(
            PlanAllowances {
                free_seconds: Some(900),
                relay_seconds: Some(10_800),
            },
            HashSet::new(),
            Some(path.clone()),
        );
        assert!(failure.is_none(), "the parent directory should have been made");
        tracker.record("phone", Duration::from_secs(60));
        assert_eq!(tracker.remaining("phone", None, Plan::Free), Some(840));

        let _ = fs::remove_dir_all(path.parent().unwrap().parent().unwrap());
    }

    #[test]
    fn a_log_that_cannot_be_opened_still_leaves_a_working_relay() {
        // A log whose parent is a regular file rather than a directory, so neither the directory
        // can be made nor the file opened. The nearest thing on a filesystem to a state directory
        // that an operator has pointed at the wrong path.
        let occupied = scratch("blocked");
        let directory = occupied.parent().unwrap().to_path_buf();
        fs::create_dir_all(&directory).unwrap();
        fs::write(&occupied, b"a file where a directory was expected").unwrap();
        let blocked = occupied.join("usage.log");

        let (tracker, failure) = QuotaTracker::with_usage_log(
            PlanAllowances {
                free_seconds: Some(900),
                relay_seconds: Some(10_800),
            },
            HashSet::new(),
            Some(blocked),
        );

        assert!(failure.is_some(), "the failure should be reported to the caller");
        // And metering still works in memory, which is the point of not making it fatal.
        tracker.record("phone", Duration::from_secs(300));
        assert_eq!(tracker.remaining("phone", None, Plan::Free), Some(600));

        let _ = fs::remove_dir_all(directory);
    }

    #[test]
    fn a_torn_last_line_costs_one_session_and_not_the_file() {
        let path = scratch("torn");
        let tracker = paid(HashSet::new(), path.clone());
        tracker.record("phone", Duration::from_secs(300));
        tracker.record("phone", Duration::from_secs(200));

        // What a machine that died mid-append leaves behind.
        tracker.flush();
        let mut text = fs::read_to_string(&path).unwrap();
        text.push_str("{\"c\":\"phone\",\"w\":20612,\"s\":");
        fs::write(&path, text).unwrap();

        let restarted = paid(HashSet::new(), path.clone());
        assert_eq!(
            restarted.remaining("phone", None, Plan::Free),
            Some(400),
            "the two whole lines still count"
        );

        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_client_id_that_would_break_a_delimiter_is_stored_whole() {
        let path = scratch("awkward");
        let awkward = "phone|\",\n\"{\"tricky";

        let first = paid(HashSet::new(), path.clone());
        first.record(awkward, Duration::from_secs(120));

        first.flush();
        let second = paid(HashSet::new(), path.clone());
        assert_eq!(second.remaining(awkward, None, Plan::Free), Some(780));
        assert_eq!(
            second.remaining("phone", None, Plan::Free),
            Some(900),
            "and it did not land on anybody else's row"
        );

        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_plan_name_survives_the_round_trip_to_its_wire_spelling() {
        for plan in [Plan::Free, Plan::Relay, Plan::Plus, Plan::Pro] {
            assert_eq!(Plan::from_wire(Some(plan.as_str())), plan);
        }
    }

    // MARK: - Charging a splice that is still running

    /// A meter over a counter with `free_minutes` in it, and the tracker behind it so a test can
    /// read the totals back. The clock is the one thing a meter owns that a test cannot wait for,
    /// which is what `backdate` is for.
    fn metered(free_minutes: u64, plan: Plan, api_key: Option<&str>) -> (Arc<QuotaTracker>, Meter) {
        let quota = Arc::new(tracker(free_minutes, 180));
        let meter = quota.account("phone", api_key, plan).start();
        (quota, meter)
    }

    /// The whole point of charging while a splice runs: the counter moves with the clock instead of
    /// waiting for the connection to end.
    #[test]
    fn a_running_splice_is_charged_as_it_goes() {
        let (quota, mut meter) = metered(15, Plan::Free, None);
        assert_eq!(meter.remaining(), Some(900), "nothing has been charged yet");

        meter.backdate(Duration::from_secs(60));
        assert_eq!(meter.charge(), Some(840), "a minute of splice is a minute off it");
        assert_eq!(quota.remaining("phone", None, Plan::Free), Some(840));

        meter.backdate(Duration::from_secs(120));
        assert_eq!(meter.charge(), Some(720), "and the next charge takes the next stretch");
        assert_eq!(quota.remaining("phone", None, Plan::Free), Some(720));
    }

    #[test]
    fn a_stalled_splice_is_charged_only_up_to_its_last_traffic() {
        let (quota, mut meter) = metered(15, Plan::Free, None);
        meter.backdate(Duration::from_secs(300));
        let last_traffic = meter.started + Duration::from_secs(60);

        assert_eq!(meter.charge_through(last_traffic), Some(840), "the 240 idle seconds are not billed");
        assert_eq!(meter.charge_through(last_traffic), Some(840), "and asking again bills nothing more");

        meter.stop_at(meter.started + Duration::from_secs(90));
        assert_eq!(meter.charge(), Some(810), "the ceiling holds against an ordinary charge");
        drop(meter);
        assert_eq!(quota.remaining("phone", None, Plan::Free), Some(810), "and against the charge a drop makes");
    }

    /// The seam a timer creates: the same seconds must not be billed by two calls. This is the
    /// property that lets a meter be charged on a tick, again when the splice ends, and once more by
    /// its own drop without any of the three double-counting.
    #[test]
    fn charging_twice_does_not_charge_the_same_second_twice() {
        let (quota, mut meter) = metered(15, Plan::Free, None);

        meter.backdate(Duration::from_secs(60));
        assert_eq!(meter.charge(), Some(840));
        assert_eq!(meter.charge(), Some(840), "a second call has nothing new to add");
        assert_eq!(meter.charge(), Some(840));

        assert_eq!(
            quota.remaining("phone", None, Plan::Free),
            Some(840),
            "one minute was spent, and it was spent once"
        );
    }

    /// A splice that ran for a fraction of a second still costs a second, which is the rule that
    /// stops a client running thousands of them to stay under a counter that rounds down. It is the
    /// splice that is floored rather than each charge, so the floor cannot be paid twice either.
    #[test]
    fn a_splice_that_barely_ran_costs_one_second() {
        let (quota, mut meter) = metered(15, Plan::Free, None);

        assert_eq!(meter.charge(), Some(899), "the floor under a splice that has barely started");
        assert_eq!(meter.charge(), Some(899), "and it is a floor under the splice, not under each call");
        assert_eq!(quota.remaining("phone", None, Plan::Free), Some(899));
    }

    /// What the splice is charged against running past its allowance looks like here: zero, and
    /// zero again however much longer it runs.
    #[test]
    fn a_meter_that_has_spent_its_allowance_reports_nothing_left() {
        let (_quota, mut meter) = metered(15, Plan::Free, None);

        meter.backdate(Duration::from_secs(1_000));
        assert_eq!(meter.charge(), Some(0), "past the allowance, and clamped rather than wrapped");

        meter.backdate(Duration::from_secs(600));
        assert_eq!(meter.charge(), Some(0), "and it stays there");
    }

    #[test]
    fn a_meter_names_its_tier_for_the_journal() {
        assert_eq!(metered(15, Plan::Free, None).1.tier(), PlanTier::Free);
        assert_eq!(metered(15, Plan::Plus, None).1.tier(), PlanTier::Paid);
        let keyed = Arc::new(QuotaTracker::new(
            PlanAllowances { free_seconds: Some(900), relay_seconds: Some(900) },
            HashSet::from(["paid-key".to_string()]),
        ));
        assert_eq!(keyed.account("phone", Some("paid-key"), Plan::Free).start().tier(), PlanTier::Unlimited);
    }

    /// The rule this whole shape has to preserve: an unlimited plan is tracked and is never
    /// reported as having nothing left. What the free plan's number is used for below is as a
    /// ruler, not as a limit, since it is the only reading of a counter that does not bound this
    /// client.
    #[test]
    fn unlimited_plans_are_charged_and_never_exhausted() {
        for plan in [Plan::Plus, Plan::Pro] {
            let (quota, mut meter) = metered(15, plan, None);

            meter.backdate(Duration::from_secs(600));
            assert_eq!(meter.charge(), None, "{plan:?} is not bounded by the counter");
            assert_eq!(
                quota.remaining("phone", None, Plan::Free),
                Some(300),
                "{plan:?} is still tracked: ten minutes of its relay show up against the free plan"
            );
        }
    }

    /// And the same for the one grant the relay holds rather than takes on trust: a key that is in
    /// the server's own list is charged for the log and never blocked.
    #[test]
    fn a_paid_key_is_charged_and_never_exhausted() {
        let mut keys = HashSet::new();
        keys.insert("real-key".to_string());
        let quota = Arc::new(QuotaTracker::new(
            PlanAllowances {
                free_seconds: Some(900),
                relay_seconds: Some(10_800),
            },
            keys,
        ));
        let mut meter = quota.account("phone", Some("real-key"), Plan::Free).start();

        meter.backdate(Duration::from_secs(600));
        assert_eq!(meter.charge(), None, "a paid key bypasses the allowance");
        assert_eq!(
            quota.remaining("phone", None, Plan::Free),
            Some(300),
            "and is recorded like everybody else"
        );
    }

    /// The cancelled splice. A task dropped under a running connection never reaches the charge at
    /// the end of the loop, and between that and the next tick there is a stretch of relay that
    /// nobody has paid for unless the meter does it on the way out.
    #[test]
    fn a_cancelled_splice_is_charged_for_what_it_ran() {
        let (quota, mut meter) = metered(15, Plan::Free, None);

        meter.backdate(Duration::from_secs(120));
        drop(meter);

        assert_eq!(
            quota.remaining("phone", None, Plan::Free),
            Some(780),
            "the drop charges the two minutes the splice ran"
        );
    }

    /// And what a running splice has charged for is on the disk before the splice ends, which is
    /// the difference this makes to a relay that restarts mid-session: it comes back knowing what
    /// was already spent rather than with the whole session uncharged.
    #[test]
    fn what_a_running_splice_has_spent_survives_a_restart() {
        let path = scratch("midway");

        let first = Arc::new(paid(HashSet::new(), path.clone()));
        let mut meter = first.account("phone", None, Plan::Free).start();
        meter.backdate(Duration::from_secs(300));
        assert_eq!(meter.charge(), Some(600));

        first.flush();
        let second = paid(HashSet::new(), path.clone());
        assert_eq!(
            second.remaining("phone", None, Plan::Free),
            Some(600),
            "the five minutes charged before the restart are still spent"
        );

        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    /// **The map has a ceiling, because a client id is a string a peer invents.** Recording under a
    /// fresh id per message used to grow the map without any bound at all, and it is the memory the
    /// relay needs to keep splicing for everybody else.
    #[test]
    fn the_counter_stops_growing_at_its_ceiling() {
        let tracker = QuotaTracker::new(PlanAllowances::default(), HashSet::new());

        for i in 0..(MAX_TRACKED_CLIENTS + 50) {
            tracker.record(&format!("invented-{i}"), Duration::from_secs(1));
        }

        let tracked = tracker.lock().usage.len();
        assert!(
            tracked <= MAX_TRACKED_CLIENTS,
            "{tracked} clients tracked, which is past the ceiling"
        );
    }

    /// And the client being charged right now is not one of the ones dropped: its seconds are the
    /// only entry in the map that somebody is actually waiting to read back.
    #[test]
    fn a_full_counter_keeps_the_client_it_is_charging() {
        let tracker = QuotaTracker::new(PlanAllowances::default(), HashSet::new());
        for i in 0..MAX_TRACKED_CLIENTS {
            tracker.record(&format!("invented-{i}"), Duration::from_secs(1));
        }

        tracker.record("the-client-being-charged", Duration::from_secs(7));

        let inner = tracker.lock();
        assert_eq!(
            inner.usage.get("the-client-being-charged"),
            Some(&WindowUsage { window: window_key(), seconds: 7 }),
            "the charge in progress survived the eviction"
        );
        assert!(inner.usage.len() <= MAX_TRACKED_CLIENTS);
    }
}
