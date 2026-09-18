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
//! **No database.** Usage lives in a HashMap for the lifetime of the process. A server restart
//! resets every client's counter, so a relay that restarts often gives away more than the
//! configured allowance — bounded now by the day rather than by the month, which makes it a
//! smaller hole than it was. Persisting `usage` is the fix if it ever needs one; the shape of
//! the map is already what a table would hold.
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
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

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

pub struct QuotaTracker {
    allowances: PlanAllowances,
    inner: Mutex<Inner>,
}

struct Inner {
    /// client_id → (window the usage belongs to, seconds used in that window)
    usage: HashMap<String, (u64, u64)>,
    paid_keys: HashSet<String>,
}

impl QuotaTracker {
    pub fn new(allowances: PlanAllowances, paid_keys: HashSet<String>) -> Self {
        Self {
            allowances,
            inner: Mutex::new(Inner {
                usage: HashMap::new(),
                paid_keys,
            }),
        }
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

    #[test]
    fn a_plan_name_survives_the_round_trip_to_its_wire_spelling() {
        for plan in [Plan::Free, Plan::Relay, Plan::Plus, Plan::Pro] {
            assert_eq!(Plan::from_wire(Some(plan.as_str())), plan);
        }
    }
}
