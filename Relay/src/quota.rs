//! Relay-time quota: free clients get a configurable number of minutes per 30-day window;
//! a valid API key grants unlimited relay access.
//!
//! **No database.** Usage lives in a HashMap for the lifetime of the process. A server restart
//! resets every free client's counter, which is fine: users cannot trigger a restart, and the
//! free allowance is small enough that occasional resets are not meaningful.
//!
//! **API keys are not credentials.** They gate relay access, but the actual privacy guarantee
//! (end-to-end encryption) holds regardless. A leaked key lets someone use the relay for free;
//! it does not let them read anyone's screen.

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// 30-day rolling window. Dividing epoch seconds by this gives a bucket number that advances
/// every 30 days — no calendar library needed, and the exact day it rolls over does not matter.
const WINDOW_SECS: u64 = 30 * 24 * 3600;

fn window_key() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        / WINDOW_SECS
}

pub struct QuotaTracker {
    free_seconds: u64,
    inner: Mutex<Inner>,
}

struct Inner {
    /// client_id → (window the usage belongs to, seconds used in that window)
    usage: HashMap<String, (u64, u64)>,
    paid_keys: HashSet<String>,
}

impl QuotaTracker {
    pub fn new(free_minutes: u64, paid_keys: HashSet<String>) -> Self {
        Self {
            free_seconds: free_minutes * 60,
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

    /// Remaining free seconds this window. `None` means the client has a valid paid key and
    /// the quota does not apply.
    pub fn remaining(&self, client_id: &str, api_key: Option<&str>) -> Option<u64> {
        if self.is_paid(api_key) {
            return None;
        }
        let inner = self.lock();
        let window = window_key();
        let used = inner
            .usage
            .get(client_id)
            .filter(|(w, _)| *w == window)
            .map(|(_, s)| *s)
            .unwrap_or(0);
        Some(self.free_seconds.saturating_sub(used))
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

    fn tracker(free_minutes: u64) -> QuotaTracker {
        QuotaTracker::new(free_minutes, HashSet::new())
    }

    #[test]
    fn a_fresh_client_has_the_full_allowance() {
        let q = tracker(15);
        assert_eq!(q.remaining("phone", None), Some(900));
    }

    #[test]
    fn usage_reduces_the_remaining_time() {
        let q = tracker(15);
        q.record("phone", Duration::from_secs(300));
        assert_eq!(q.remaining("phone", None), Some(600));
    }

    #[test]
    fn exhausted_quota_clamps_at_zero_not_wraps() {
        let q = tracker(15);
        q.record("phone", Duration::from_secs(1000));
        assert_eq!(q.remaining("phone", None), Some(0));
    }

    #[test]
    fn a_valid_paid_key_bypasses_the_quota() {
        let mut keys = HashSet::new();
        keys.insert("valid-key".to_string());
        let q = QuotaTracker::new(15, keys);
        q.record("phone", Duration::from_secs(1000));
        assert_eq!(q.remaining("phone", Some("valid-key")), None);
    }

    #[test]
    fn an_invalid_key_falls_through_to_the_free_quota() {
        let mut keys = HashSet::new();
        keys.insert("real-key".to_string());
        let q = QuotaTracker::new(15, keys);
        q.record("phone", Duration::from_secs(1000));
        assert_eq!(q.remaining("phone", Some("wrong-key")), Some(0));
        assert_eq!(q.remaining("phone", None), Some(0));
    }

    #[test]
    fn different_clients_have_independent_quotas() {
        let q = tracker(15);
        q.record("phone-a", Duration::from_secs(500));
        assert_eq!(q.remaining("phone-a", None), Some(400));
        assert_eq!(q.remaining("phone-b", None), Some(900));
    }

    #[test]
    fn sub_second_splices_charge_at_least_one_second() {
        let q = tracker(15);
        for _ in 0..900 {
            q.record("phone", Duration::from_millis(1));
        }
        assert_eq!(q.remaining("phone", None), Some(0));
    }
}
