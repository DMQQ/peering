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
//! **A day, not a month.** The window is deliberately short. An allowance of an hour a day is
//! something a person can plan around — connect now, or wait until tomorrow — where a monthly
//! pot is either unspent or gone, and the failure mode of "gone" is a paywall in front of
//! someone who has only just worked out that the relay is the point. Thirty times an hour is
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
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use tracing::warn;

use crate::config::PlanAllowances;

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

/// One line of the usage log.
///
/// Short field names because they are written a few hundred thousand times over a relay's life
/// and read only by this file. Serde rather than a hand-rolled format so that a client id
/// containing a pipe, a comma, a newline or anything else is stored and read back unchanged.
#[derive(Serialize, Deserialize)]
struct UsageLine {
    /// The client's device id.
    c: String,
    /// The window the seconds belong to.
    w: u64,
    /// Seconds relayed in that window, for that one charge. A session writes several of these if
    /// it runs long enough, and what is read back is their sum.
    s: u64,
}

/// How large the log is allowed to grow before it is rewritten down to one line per client.
///
/// Four megabytes is on the order of a hundred thousand charges. Each of those is a stretch of a
/// session rather than a whole one, so the file fills faster than it did when a session wrote one
/// line at the end, and the rewrite that follows is the same trade it always was: one line per
/// client against a file that grows for a day at a time. The rewrite takes the same lock an append
/// does, which is why it happens on the task that has just charged a session rather than on a
/// timer behind it: there is no background task here that could get out of step with the file, and
/// nothing to shut down cleanly.
const COMPACT_BYTES: u64 = 4 * 1024 * 1024;

/// The counter's second home, on disk.
///
/// Held open in append mode for the life of the process, so recording a session is one small
/// write rather than an open, a write and a close.
struct UsageLog {
    path: PathBuf,
    file: File,
    /// Bytes in the file, so compaction can be decided without asking the filesystem.
    written: u64,
}

impl UsageLog {
    /// Opens the log and reads back what it already held.
    ///
    /// The parent directory is created if it is missing, because the likeliest reason a
    /// configured path does not exist yet is that the operator has just written the line into the
    /// environment file and not yet made the directory.
    fn open(path: PathBuf) -> io::Result<(Self, HashMap<String, (u64, u64)>)> {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            fs::create_dir_all(parent)?;
        }
        let usage = Self::replay(&path)?;
        let file = OpenOptions::new().create(true).append(true).open(&path)?;
        let written = file.metadata().map(|m| m.len()).unwrap_or(0);
        Ok((Self { path, file, written }, usage))
    }

    /// The map the tracker keeps, rebuilt from the file.
    ///
    /// **Only the newest window in the file survives**, and that is not a heuristic: nothing ever
    /// asks for an older one, because ``QuotaTracker::remaining`` filters on the current window
    /// and ``record`` overwrites an entry whose window has moved on. An entry from yesterday
    /// would be a number with no reader.
    ///
    /// A line that will not parse is skipped rather than made fatal, which is the point of one
    /// object per line: the failure this is written for is a machine that died mid-append, and
    /// what it should cost is the seconds of one charge, not the whole file.
    fn replay(path: &Path) -> io::Result<HashMap<String, (u64, u64)>> {
        let text = match fs::read_to_string(path) {
            Ok(text) => text,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(HashMap::new()),
            Err(error) => return Err(error),
        };

        let mut newest = 0u64;
        let mut entries = Vec::new();
        for line in text.lines() {
            let Ok(entry) = serde_json::from_str::<UsageLine>(line) else { continue };
            newest = newest.max(entry.w);
            entries.push(entry);
        }

        let mut usage: HashMap<String, (u64, u64)> = HashMap::new();
        for entry in entries.into_iter().filter(|entry| entry.w == newest) {
            let slot = usage.entry(entry.c).or_insert((newest, 0));
            slot.1 = slot.1.saturating_add(entry.s);
        }
        Ok(usage)
    }

    /// Adds one charge to the log and puts it on the disk before returning.
    ///
    /// Synced rather than merely written, and it is worth saying why that is not paranoia: the
    /// case this file exists for is a relay that stops without warning, and a write still sitting
    /// in the page cache when the machine goes down is exactly those seconds being free again.
    /// Charging a running splice on a timer is what makes this the more valuable half of the
    /// arrangement, since a session that has not ended yet is now also a session that has paid for
    /// what it has used. The cost is one fsync per charge, which is nothing beside the relay time
    /// it accounts for.
    fn append(&mut self, client_id: &str, window: u64, secs: u64) -> io::Result<()> {
        let mut line = serde_json::to_string(&UsageLine {
            c: client_id.to_string(),
            w: window,
            s: secs,
        })
        .map_err(io::Error::other)?;
        line.push('\n');
        self.file.write_all(line.as_bytes())?;
        self.file.sync_data()?;
        self.written += line.len() as u64;
        Ok(())
    }

    /// Whether a compaction would actually make the file smaller.
    ///
    /// **The size of the file was the whole of this test, and it is not enough.** Compaction is only
    /// worth anything if it has something to drop, and what it drops is every line whose window has
    /// passed and every repeat of a client already written: charges coalesce per client per window.
    /// An attacker spending a second each under a hundred thousand invented ids produces a file
    /// with nothing in it to coalesce, and a rewrite that does not shrink the file is a rewrite that
    /// happens again on the next append and the next. Four megabytes rewritten per charge is a far
    /// worse outcome than the file it was meant to bound.
    ///
    /// So the test is "the file is big *and* what compaction would keep is at most half of it",
    /// which is the condition that makes the rewrite amortised.
    fn needs_compaction(&self, usage: &HashMap<String, (u64, u64)>, window: u64) -> bool {
        if self.written < COMPACT_BYTES {
            return false;
        }
        self.written >= 2 * Self::compacted_size(usage, window)
    }

    /// What the file would weigh after a compaction, near enough to decide with.
    ///
    /// The id is counted at its own length, which is the term that matters: ids are chosen by the
    /// peer and can be up to 256 bytes, so an estimate that assumed a UUID would be wrong by an
    /// order of magnitude in exactly the case this exists for. The rest is the JSON envelope around
    /// it, `{"c":"","w":0,"s":0}` and a newline.
    ///
    /// An id full of characters the encoder escapes (a quote, a newline) weighs up to twice what is
    /// counted here, which makes the estimate low and the rewrite happen a little sooner than it
    /// had to. That is the harmless direction: a compaction early is a compaction that still
    /// shrinks the file, and the test above is what rules out the one that would not.
    fn compacted_size(usage: &HashMap<String, (u64, u64)>, window: u64) -> u64 {
        const LINE_OVERHEAD: u64 = 24;
        usage
            .iter()
            .filter(|(_, (entry_window, secs))| *entry_window == window && *secs > 0)
            .map(|(id, (_, secs))| {
                LINE_OVERHEAD + id.len() as u64 + secs.to_string().len() as u64
            })
            .sum()
    }

    /// Rewrites the file as one line per client, for the current window only.
    ///
    /// Through a temporary file and a rename, so a machine that dies in the middle leaves the old
    /// log whole rather than a half-written one that replays as nothing. That matters more than it
    /// looks: the file being replaced is the only record of what has already been spent.
    fn compact(&mut self, usage: &HashMap<String, (u64, u64)>, window: u64) -> io::Result<()> {
        let mut body = String::new();
        for (client_id, (entry_window, secs)) in usage {
            if *entry_window != window || *secs == 0 {
                continue;
            }
            let line = serde_json::to_string(&UsageLine {
                c: client_id.clone(),
                w: window,
                s: *secs,
            })
            .map_err(io::Error::other)?;
            body.push_str(&line);
            body.push('\n');
        }

        let temporary = self.path.with_extension("log.tmp");
        fs::write(&temporary, body)?;
        fs::rename(&temporary, &self.path)?;
        self.file = OpenOptions::new().create(true).append(true).open(&self.path)?;
        self.written = self.file.metadata().map(|m| m.len()).unwrap_or(0);
        Ok(())
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
    inner: Mutex<Inner>,
}

struct Inner {
    /// client_id → (window the usage belongs to, seconds used in that window)
    usage: HashMap<String, (u64, u64)>,
    paid_keys: HashSet<String>,
    /// Absent when no path was configured or the file would not open. See ``with_usage_log``.
    log: Option<UsageLog>,
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
            inner: Mutex::new(Inner {
                usage: HashMap::new(),
                paid_keys,
                log: None,
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
            Some(path) => match UsageLog::open(path) {
                Ok((log, usage)) => (Some(log), usage, None),
                Err(error) => (None, HashMap::new(), Some(error)),
            },
            None => (None, HashMap::new(), None),
        };

        let tracker = Self {
            allowances,
            charge_period: CHARGE_PERIOD,
            inner: Mutex::new(Inner {
                usage,
                paid_keys,
                log,
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

    /// What this plan is allowed in one window. `None` is unlimited, which is what the top two
    /// plans buy and is deliberately not a number: any number is eventually reached.
    fn allowance(&self, plan: Plan) -> Option<u64> {
        match plan {
            Plan::Free => self.allowances.free_seconds,
            Plan::Relay => self.allowances.relay_seconds,
            Plan::Plus | Plan::Pro => None,
        }
    }

    /// Remaining seconds this window. `None` means the quota does not apply to this client, either
    /// because they hold a valid paid key or because the plan they stated has no limit.
    ///
    /// **Usage is not per plan.** The counter is relay time spent in this window and the allowance
    /// is what the plan permits, so a client that spends twenty minutes on free and then subscribes
    /// has its remaining Relay allowance reduced by those twenty minutes rather than being handed a
    /// fresh three hours. That is the honest reading of a metered day, and it is also what makes an
    /// upgrade take effect mid-window with no state to migrate.
    pub fn remaining(&self, client_id: &str, api_key: Option<&str>, plan: Plan) -> Option<u64> {
        if self.is_paid(api_key) {
            return None;
        }
        let allowance = self.allowance(plan)?;

        let inner = self.lock();
        let window = window_key();
        let used = inner
            .usage
            .get(client_id)
            .filter(|(w, _)| *w == window)
            .map(|(_, s)| *s)
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
        let entry = inner.usage.entry(client_id.to_string()).or_insert((window, 0));
        if entry.0 != window {
            *entry = (window, 0);
        }
        entry.1 = entry.1.saturating_add(secs);

        // Destructured rather than reached through `inner`, so the log and the map can be held at
        // once: compaction is handed the map it is writing down.
        let Inner { usage, log, evicting, .. } = &mut *inner;

        if usage.len() > MAX_TRACKED_CLIENTS {
            Self::evict(usage, window, client_id, evicting);
        } else if *evicting {
            // Back under the ceiling, so the next episode is worth a line of its own.
            *evicting = false;
        }

        let Some(log) = log.as_mut() else { return };

        // Logged and carried on with, both here and below. A file that will not take a write is a
        // relay that over-counts after its next restart, and a relay that stopped splicing because
        // its state directory filled up would be a far bigger outage than the one being prevented.
        // The map stays the truth for this run either way, so the client is still metered correctly
        // until then.
        //
        // **The writing happens off the runtime thread.** Every append is a write and an fsync, and
        // the callers are tasks: the splice's meter tick and the meter's drop. A file write is
        // blocking work by definition, and a service where a peer can arrange for thousands of them
        // is a service where the reactor spends its time waiting on a disk. `block_in_place` hands
        // the blocking work to a thread of its own and lets the runtime start another worker, which
        // is exactly the case it exists for. It is asked for only when there is a runtime: the
        // unit tests call this from plain `#[test]` functions, where there is no reactor to starve
        // and the call would panic.
        //
        // One thing a future change has to know: `block_in_place` panics on a current-thread
        // runtime, and `Handle::try_current` returns one just as happily as a multi-threaded one.
        // The binary runs `#[tokio::main]` with the default multi-thread flavour, so the panic
        // would arrive on the first charge of the first session rather than in production quietly.
        let writing = |log: &mut UsageLog| -> io::Result<()> {
            if tokio::runtime::Handle::try_current().is_ok() {
                tokio::task::block_in_place(|| log.append(client_id, window, secs))
            } else {
                log.append(client_id, window, secs)
            }
        };
        if let Err(error) = writing(log) {
            warn!(%error, "could not write to the usage log; usage will not survive a restart");
            return;
        }

        if log.needs_compaction(usage, window) {
            let compacting = |log: &mut UsageLog| -> io::Result<()> {
                if tokio::runtime::Handle::try_current().is_ok() {
                    tokio::task::block_in_place(|| log.compact(usage, window))
                } else {
                    log.compact(usage, window)
                }
            };
            if let Err(error) = compacting(log) {
                warn!(%error, "could not compact the usage log; it will be tried again on the next session");
            }
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
        usage: &mut HashMap<String, (u64, u64)>,
        window: u64,
        keep: &str,
        evicting: &mut bool,
    ) {
        usage.retain(|_, (entry_window, _)| *entry_window == window);
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
        let run = self.started.elapsed().as_secs().max(1);
        let owed = run.saturating_sub(self.recorded);
        if owed > 0 {
            self.recorded = run;
            self.account
                .tracker
                .record(&self.account.client_id, Duration::from_secs(owed));
        }
        self.remaining()
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
    use super::*;

    /// Fifteen minutes free and three hours on Relay, which is what the defaults are in the small:
    /// two different numbers, so a test that confuses the two plans fails rather than passes.
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
            Some(10_800),
            "Relay is three hours where free is fifteen minutes"
        );
    }

    #[test]
    fn a_relay_plan_is_still_metered() {
        let q = default_tracker();
        q.record("phone", Duration::from_secs(300));

        assert_eq!(q.remaining("phone", None, Plan::Relay), Some(10_500));
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

        // Twenty minutes on free, then a subscription: the three hours are three hours from the
        // window, not from the upgrade.
        assert_eq!(q.remaining("phone", None, Plan::Relay), Some(10_200));
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

        let second = paid(HashSet::new(), path.clone());
        assert_eq!(second.remaining("phone", None, Plan::Free), Some(400));

        // And recording again on top of the replay adds to the total rather than replacing it.
        second.record("phone", Duration::from_secs(100));
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
    fn compaction_keeps_the_totals_and_shrinks_the_file() {
        let path = scratch("compact");

        let (tracker, failure) = QuotaTracker::with_usage_log(
            PlanAllowances {
                free_seconds: Some(900),
                relay_seconds: Some(10_800),
            },
            HashSet::new(),
            Some(path.clone()),
        );
        assert!(failure.is_none());
        for _ in 0..50 {
            tracker.record("phone", Duration::from_secs(4));
        }

        let before = fs::metadata(&path).unwrap().len();

        // The rewrite itself, called directly rather than by writing four megabytes through it.
        {
            let mut inner = tracker.lock();
            let Inner { usage, log, .. } = &mut *inner;
            log.as_mut().unwrap().compact(usage, window_key()).unwrap();
        }

        assert!(
            fs::metadata(&path).unwrap().len() < before,
            "compaction should make the file smaller"
        );

        let restarted = paid(HashSet::new(), path.clone());
        assert_eq!(
            restarted.remaining("phone", None, Plan::Free),
            Some(700),
            "and the total it kept is the same one"
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
            Some(&(window_key(), 7)),
            "the charge in progress survived the eviction"
        );
        assert!(inner.usage.len() <= MAX_TRACKED_CLIENTS);
    }

    /// **A compaction that cannot shrink the file must not happen.** It used to be triggered by the
    /// file's size alone, which is right while charges coalesce per client and wrong the moment an
    /// attacker spends a second under each of a hundred thousand invented ids: every rewrite keeps
    /// every line, so the next append triggers another, and the relay spends its time rewriting
    /// four megabytes per charge.
    #[test]
    fn compaction_is_not_attempted_when_there_is_nothing_to_drop() {
        let mut usage: HashMap<String, (u64, u64)> = HashMap::new();
        let window = 20_000u64;
        // Twenty thousand clients with long ids, all in the current window: the compacted file is
        // most of a megabyte and compaction would keep nearly all of it.
        for i in 0..20_000 {
            usage.insert(format!("{i:-<200}"), (window, 60));
        }
        let compacted = UsageLog::compacted_size(&usage, window);
        assert!(compacted > 4 * 1024 * 1024);

        let log = UsageLog {
            path: PathBuf::from("/dev/null"),
            file: OpenOptions::new().append(true).open("/dev/null").unwrap(),
            written: 4 * 1024 * 1024 + 1,
        };
        assert!(
            !log.needs_compaction(&usage, window),
            "a rewrite that would keep {compacted} of {} bytes is not worth doing",
            log.written
        );
    }

    /// The other half: when there *is* something to drop, it goes ahead. One client with an old
    /// window beside a big file is the ordinary case this was written for.
    #[test]
    fn compaction_is_attempted_when_there_is_something_to_drop() {
        let mut usage: HashMap<String, (u64, u64)> = HashMap::new();
        let window = 20_000u64;
        usage.insert("phone".to_string(), (window, 3_600));
        for i in 0..1_000 {
            usage.insert(format!("yesterday-{i}"), (window - 1, 3_600));
        }

        let log = UsageLog {
            path: PathBuf::from("/dev/null"),
            file: OpenOptions::new().append(true).open("/dev/null").unwrap(),
            written: COMPACT_BYTES + 1,
        };
        assert!(log.needs_compaction(&usage, window));
    }
}
