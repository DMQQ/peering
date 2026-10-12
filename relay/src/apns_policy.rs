//! What Apple's answer to a push means, decided without a socket in the way.
//!
//! The rules come from Apple's "Handling notification responses from APNs": a reason is only
//! believed alongside the status Apple documents for it, `BadDeviceToken` is the one refusal worth
//! a second host, and a provider token may not be replaced more than once every twenty minutes.

use std::fmt;
use std::time::{Duration, Instant};

/// Apple answers `TooManyProviderTokenUpdates` to a token replaced more often than this.
pub const MIN_JWT_REFRESH: Duration = Duration::from_secs(20 * 60);

const BREAKER_FIRST_OPEN: Duration = Duration::from_secs(30);
/// Apple's own number for retrying after a 5xx.
const BREAKER_LONGEST_OPEN: Duration = Duration::from_secs(15 * 60);
const BREAKER_THRESHOLD: u32 = 3;

/// An answer other than success: Apple's status and, when the body carried one, its `reason`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApnsRefusal {
    pub status: u16,
    pub reason: Option<String>,
}

impl ApnsRefusal {
    pub fn parse(status: u16, body: &[u8]) -> Self {
        let reason = serde_json::from_slice::<serde_json::Value>(body)
            .ok()
            .and_then(|value| value.get("reason")?.as_str().map(str::to_owned));
        Self { status, reason }
    }

    fn reason_is(&self, name: &str, status: u16) -> bool {
        self.status == status && self.reason.as_deref() == Some(name)
    }

    /// The token is dead for this topic: Apple's 410, whichever of its two reasons.
    pub fn is_dead_token(&self) -> bool {
        self.status == 410 && matches!(self.reason.as_deref(), Some("Unregistered" | "ExpiredToken"))
    }

    pub fn is_throttle(&self) -> bool {
        self.status == 429
    }

    pub fn is_server_side(&self) -> bool {
        self.status >= 500
    }

    /// A token for the other environment is told apart from a dead one only by the host that
    /// refuses it, so this is the single refusal that is retried on the other host.
    pub fn is_wrong_environment(&self) -> bool {
        self.reason_is("BadDeviceToken", 400)
    }

    pub fn is_stale_provider_token(&self) -> bool {
        self.status == 403 && matches!(self.reason.as_deref(), Some("ExpiredProviderToken" | "InvalidProviderToken"))
    }
}

impl fmt::Display for ApnsRefusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.reason {
            Some(reason) => write!(f, "{} {reason}", self.status),
            None => write!(f, "{}", self.status),
        }
    }
}

/// Stops sending after repeated 429 and 5xx answers, so a struggling APNs is not hammered.
///
/// Opens after three in a row, for 30 seconds, doubling to Apple's 15 minutes; any success closes
/// it. A single 5xx does not open it: a lost approval prompt costs more than one more attempt.
#[derive(Default)]
pub struct CircuitBreaker {
    consecutive: u32,
    opened: u32,
    open_until: Option<Instant>,
}

impl CircuitBreaker {
    pub fn blocked(&self, now: Instant) -> bool {
        self.open_until.is_some_and(|until| now < until)
    }

    pub fn record_failure(&mut self, now: Instant) {
        self.consecutive += 1;
        if self.consecutive < BREAKER_THRESHOLD {
            return;
        }
        let open_for = BREAKER_FIRST_OPEN
            .saturating_mul(1u32 << self.opened.min(10))
            .min(BREAKER_LONGEST_OPEN);
        self.opened = self.opened.saturating_add(1);
        self.open_until = Some(now + open_for);
        self.consecutive = 0;
    }

    pub fn record_success(&mut self) {
        *self = Self::default();
    }
}

/// Whether a provider token minted `age` ago may be replaced now.
pub fn may_refresh_jwt(age: Duration) -> bool {
    age >= MIN_JWT_REFRESH
}

#[cfg(test)]
mod tests {
    use super::*;

    fn refusal(status: u16, reason: &str) -> ApnsRefusal {
        ApnsRefusal::parse(status, format!(r#"{{"reason":"{reason}"}}"#).as_bytes())
    }

    #[test]
    fn the_reason_is_read_from_the_json_body() {
        let parsed = ApnsRefusal::parse(410, br#"{"reason":"Unregistered","timestamp":1700000000000}"#);
        assert_eq!(parsed.reason.as_deref(), Some("Unregistered"));
        assert_eq!(ApnsRefusal::parse(500, b"not json").reason, None);
        assert_eq!(ApnsRefusal::parse(500, b"").to_string(), "500");
    }

    #[test]
    fn only_bad_device_token_on_a_400_tries_the_other_host() {
        assert!(refusal(400, "BadDeviceToken").is_wrong_environment());
        for (status, reason) in [
            (400, "DeviceTokenNotForTopic"),
            (403, "Forbidden"),
            (410, "ExpiredToken"),
            (410, "Unregistered"),
            (413, "PayloadTooLarge"),
            (500, "BadDeviceToken"),
        ] {
            assert!(!refusal(status, reason).is_wrong_environment(), "{status} {reason}");
        }
    }

    #[test]
    fn a_dead_token_needs_a_410() {
        assert!(refusal(410, "Unregistered").is_dead_token());
        assert!(refusal(410, "ExpiredToken").is_dead_token());
        assert!(!refusal(400, "Unregistered").is_dead_token());
        assert!(!refusal(410, "Other").is_dead_token());
    }

    #[test]
    fn a_stale_provider_token_needs_a_403() {
        assert!(refusal(403, "ExpiredProviderToken").is_stale_provider_token());
        assert!(refusal(403, "InvalidProviderToken").is_stale_provider_token());
        assert!(!refusal(403, "Forbidden").is_stale_provider_token());
        assert!(!refusal(400, "ExpiredProviderToken").is_stale_provider_token());
    }

    #[test]
    fn throttles_and_server_errors_are_told_apart_by_status() {
        assert!(refusal(429, "TooManyRequests").is_throttle());
        assert!(refusal(503, "ServiceUnavailable").is_server_side());
        assert!(!refusal(400, "BadTopic").is_server_side());
    }

    #[test]
    fn the_breaker_opens_on_the_third_failure_and_doubles() {
        let start = Instant::now();
        let mut breaker = CircuitBreaker::default();
        breaker.record_failure(start);
        breaker.record_failure(start);
        assert!(!breaker.blocked(start));
        breaker.record_failure(start);
        assert!(breaker.blocked(start + Duration::from_secs(29)));
        assert!(!breaker.blocked(start + Duration::from_secs(31)));

        let later = start + Duration::from_secs(60);
        for _ in 0..3 {
            breaker.record_failure(later);
        }
        assert!(breaker.blocked(later + Duration::from_secs(59)));
        assert!(!breaker.blocked(later + Duration::from_secs(61)));
    }

    #[test]
    fn the_breaker_never_stays_open_longer_than_fifteen_minutes() {
        let start = Instant::now();
        let mut breaker = CircuitBreaker::default();
        for _ in 0..60 {
            breaker.record_failure(start);
        }
        assert!(!breaker.blocked(start + BREAKER_LONGEST_OPEN + Duration::from_secs(1)));
    }

    #[test]
    fn a_success_closes_the_breaker_and_resets_its_count() {
        let start = Instant::now();
        let mut breaker = CircuitBreaker::default();
        for _ in 0..3 {
            breaker.record_failure(start);
        }
        breaker.record_success();
        assert!(!breaker.blocked(start));
        breaker.record_failure(start);
        breaker.record_failure(start);
        assert!(!breaker.blocked(start));
    }

    #[test]
    fn a_provider_token_is_not_replaced_within_twenty_minutes() {
        assert!(!may_refresh_jwt(Duration::from_secs(19 * 60)));
        assert!(may_refresh_jwt(Duration::from_secs(20 * 60)));
    }
}
