//! Relay-time quota: how much relay a client gets is decided by the plan it states in the
//! handshake — free is the smallest allowance, the cheapest subscription is larger, and the two
//! above that are not metered at all.
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
//! finished session, a few hundred rows, and a question that is only ever "how many seconds has
//! this client spent in this window". A database buys atomic updates and queries, and neither is
//! wanted; the only thing it would replace is the full rewrite that compaction does, and at this
//! size that rewrite is cheaper than the dependency.
//!
//! Setting the path is the operator's business, and leaving it unset is legal: the relay runs
//! with the counter in memory and says so at startup. A default path would be a relay that looks
//! healthy and silently records nothing, which is worse than one that admits it.
//!
//! **Where the plan comes from is `storekit`'s business, not this module's.** A client that sends
//! the receipt Apple signed for its purchase is metered by the product that receipt names; a client
//! that sends nothing, or nothing that verifies, is metered by the plan it claims — for now, with
//! the reasoning and the condition for ending that written out in `storekit`. What matters here is
//! only that a `Plan` arrives having already been decided: this module never reads a string a
//! client sent, and there is no spelling of "unlimited" it can be handed by accident.
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
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

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
    /// Seconds relayed in that window, for that one session.
    s: u64,
}

/// How large the log is allowed to grow before it is rewritten down to one line per client.
///
/// Four megabytes is on the order of a hundred thousand finished sessions, against a running
/// total of at most one line per client that has relayed in the current day. The rewrite takes
/// the same lock an append does, which is why it happens on the thread that has just finished a
/// session rather than on a timer behind it: there is no background task here that could get out
/// of step with the file, and nothing to shut down cleanly.
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
    /// what it should cost is one session's seconds, not the whole file.
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

    /// Adds one finished session, and puts it on the disk before returning.
    ///
    /// Synced rather than merely written, and it is worth saying why that is not paranoia: the
    /// case this file exists for is a relay that stops without warning, and a write still sitting
    /// in the page cache when the machine goes down is exactly that session being free again.
    /// The cost is one fsync per finished session, which is nothing beside the session itself.
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

    fn needs_compaction(&self) -> bool {
        self.written >= COMPACT_BYTES
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

pub struct QuotaTracker {
    allowances: PlanAllowances,
    inner: Mutex<Inner>,
}

struct Inner {
    /// client_id → (window the usage belongs to, seconds used in that window)
    usage: HashMap<String, (u64, u64)>,
    paid_keys: HashSet<String>,
    /// Absent when no path was configured or the file would not open. See ``with_usage_log``.
    log: Option<UsageLog>,
}

impl QuotaTracker {
    /// A tracker whose counter lives only as long as the process does.
    ///
    /// Used by the tests, and by a deployment that has not configured ``PEERINGD_USAGE_LOG``.
    pub fn new(allowances: PlanAllowances, paid_keys: HashSet<String>) -> Self {
        Self {
            allowances,
            inner: Mutex::new(Inner {
                usage: HashMap::new(),
                paid_keys,
                log: None,
            }),
        }
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
            inner: Mutex::new(Inner {
                usage,
                paid_keys,
                log,
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

    /// Records actual relay time. Called when a TCP splice ends so the deduction is real usage,
    /// not an estimate made at session start.
    ///
    /// A minimum of one second is charged even for very short splices, so a client cannot run a
    /// large number of sub-second sessions to stay under the counter.
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
        let Inner { usage, log, .. } = &mut *inner;
        let Some(log) = log.as_mut() else { return };

        // Logged and carried on with, both here and below. A file that will not take a write is a
        // relay that over-counts after its next restart, and a relay that stopped splicing because
        // its state directory filled up would be a far bigger outage than the one being prevented.
        // The map stays the truth for this run either way, so the client is still metered correctly
        // until then.
        if let Err(error) = log.append(client_id, window, secs) {
            warn!(%error, "could not write to the usage log; usage will not survive a restart");
            return;
        }

        if log.needs_compaction() {
            if let Err(error) = log.compact(usage, window) {
                warn!(%error, "could not compact the usage log; it will be tried again on the next session");
            }
        }
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
}
