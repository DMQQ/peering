//! Live Activity pushes: validating a host's `notifyActivity`, building the APNs request for it,
//! and limiting how fast one connection may send them.
//!
//! The relay never reads inside `contentState` or `attributes`. They are the host's and the app's
//! business, so they are size-checked and passed through, and nothing here logs them.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

use crate::apns_policy::ApnsRefusal;
use crate::protocol::hex_bytes;

/// Apple caps a Live Activity payload at 4 KB.
const MAX_BODY_BYTES: usize = 4096;
pub const MAX_CONTENT_STATE_BYTES: usize = 3500;
const MAX_TOKEN_BYTES: usize = 128;
const MAX_ATTRIBUTES_TYPE_BYTES: usize = 128;
const MAX_ALERT_TITLE_BYTES: usize = 256;
const MAX_ALERT_BODY_BYTES: usize = 512;
const END_DISMISSAL_SECONDS: u64 = 4 * 60 * 60;

const BURST: f64 = 5.0;
const REFILL_PER_SECOND: f64 = 1.0;
const MAX_TRACKED_TOKENS: usize = 64;

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ActivityKind {
    Session,
    AgentChat,
    Terminal,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ActivityEvent {
    Start,
    Update,
    End,
}

impl ActivityEvent {
    fn as_str(self) -> &'static str {
        match self {
            Self::Start => "start",
            Self::Update => "update",
            Self::End => "end",
        }
    }

    fn default_priority(self) -> u8 {
        match self {
            Self::Update => 5,
            Self::Start | Self::End => 10,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ActivityEnvironment {
    Production,
    Sandbox,
}

/// The body of a `notifyActivity` message.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ActivityPush {
    pub activity_token: String,
    pub activity: ActivityKind,
    pub event: ActivityEvent,
    pub content_state: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stale_seconds: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub priority: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attributes_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attributes: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub alert_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub alert_body: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub environment: Option<ActivityEnvironment>,
    /// For `end` only: seconds until the card leaves the Lock Screen, at most four hours. Absent
    /// means four hours; zero means now.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dismissal_seconds: Option<u32>,
    /// Echoed in `activityRefused` so the host can tell which push was refused. Never logged.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
}

pub const MAX_REQUEST_ID_CHARS: usize = 64;

/// Why a push was not sent, as the host is told. A closed set: the host acts on it, so it must
/// never carry text from Apple or from the host's own payload.
#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ActivityRefusal {
    /// The message itself is unusable: a missing start field, an oversized or non-object state.
    InvalidPayload,
    /// Malformed, or APNs said BadDeviceToken, Unregistered or ExpiredToken. The host should forget it.
    InvalidToken,
    /// APNs refused it for another reason.
    Rejected,
    /// The relay has no APNs credentials, or could not reach Apple.
    Unavailable,
}

impl ActivityRefusal {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::InvalidPayload => "invalidPayload",
            Self::InvalidToken => "invalidToken",
            Self::Rejected => "rejected",
            Self::Unavailable => "unavailable",
        }
    }
}

/// What APNs did with a push.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActivityFailure {
    TokenRejected,
    Rejected,
    Unavailable,
    /// Apple, or this relay's own limits, asked for a pause. The host is told `unavailable`: the
    /// refusal set is closed and an older host cannot decode a case it does not know.
    Throttled,
}

impl ActivityFailure {
    pub fn from_refusal(refusal: &ApnsRefusal) -> Self {
        const DEAD_TOKEN: [&str; 4] = ["BadDeviceToken", "Unregistered", "ExpiredToken", "DeviceTokenNotForTopic"];
        if refusal.is_throttle() {
            Self::Throttled
        } else if refusal.is_server_side() {
            Self::Unavailable
        } else if refusal.reason.as_deref().is_some_and(|reason| DEAD_TOKEN.contains(&reason)) {
            Self::TokenRejected
        } else {
            Self::Rejected
        }
    }

    pub fn as_str(self) -> &'static str {
        self.refusal().as_str()
    }

    pub fn refusal(self) -> ActivityRefusal {
        match self {
            Self::TokenRejected => ActivityRefusal::InvalidToken,
            Self::Rejected => ActivityRefusal::Rejected,
            Self::Unavailable | Self::Throttled => ActivityRefusal::Unavailable,
        }
    }
}

/// The parts of the APNs request that depend on the push; the client adds auth and topic.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActivityRequest {
    pub priority: u8,
    pub expiration: Option<u64>,
    pub body: String,
}

/// The refusal for a `notifyActivity` that did not decode, so the host is told which push failed
/// instead of getting a generic protocol error. `None` when the message is some other kind.
pub fn refusal_for_undecodable(text: &str) -> Option<(ActivityRefusal, Option<String>)> {
    let value: Value = serde_json::from_str(text).ok()?;
    if value.get("type")?.as_str()? != "notifyActivity" {
        return None;
    }
    let request_id = value
        .get("requestId")
        .and_then(Value::as_str)
        .filter(|id| id.chars().count() <= MAX_REQUEST_ID_CHARS)
        .map(str::to_owned);
    Some((ActivityRefusal::InvalidPayload, request_id))
}

fn within(text: &str, limit: usize) -> bool {
    text.len() <= limit
}

pub fn token_is_well_formed(token: &str) -> bool {
    !token.is_empty() && hex_bytes(token, MAX_TOKEN_BYTES).is_some()
}

pub fn build(push: &ActivityPush, now: u64) -> Result<ActivityRequest, ActivityRefusal> {
    if !token_is_well_formed(&push.activity_token) {
        return Err(ActivityRefusal::InvalidToken);
    }
    let Value::Object(_) = &push.content_state else {
        return Err(ActivityRefusal::InvalidPayload);
    };
    let state_bytes = serde_json::to_string(&push.content_state).map_err(|_| ActivityRefusal::InvalidPayload)?;
    if !within(&state_bytes, MAX_CONTENT_STATE_BYTES) {
        return Err(ActivityRefusal::InvalidPayload);
    }

    if push.request_id.as_deref().is_some_and(|id| id.chars().count() > MAX_REQUEST_ID_CHARS) {
        return Err(ActivityRefusal::InvalidPayload);
    }

    let priority = push.priority.unwrap_or_else(|| push.event.default_priority());
    if !matches!(priority, 5 | 10) {
        return Err(ActivityRefusal::InvalidPayload);
    }

    let alert = match (&push.alert_title, &push.alert_body) {
        (Some(title), Some(body)) => {
            if !within(title, MAX_ALERT_TITLE_BYTES) || !within(body, MAX_ALERT_BODY_BYTES) {
                return Err(ActivityRefusal::InvalidPayload);
            }
            Some(json!({ "title": title, "body": body }))
        }
        (None, None) => None,
        _ => return Err(ActivityRefusal::InvalidPayload),
    };

    let stale = push.stale_seconds.map(|seconds| now.saturating_add(u64::from(seconds)));
    let mut aps = Map::new();
    aps.insert("timestamp".into(), json!(now));
    aps.insert("event".into(), json!(push.event.as_str()));
    aps.insert("content-state".into(), push.content_state.clone());
    if let Some(stale) = stale {
        aps.insert("stale-date".into(), json!(stale));
    }
    if push.event == ActivityEvent::End {
        let seconds = push.dismissal_seconds.map_or(END_DISMISSAL_SECONDS, |s| u64::from(s).min(END_DISMISSAL_SECONDS));
        aps.insert("dismissal-date".into(), json!(now.saturating_add(seconds)));
    }
    if push.event == ActivityEvent::Start {
        let attributes_type = push.attributes_type.as_deref().filter(|name| !name.is_empty());
        let (Some(attributes_type), Some(attributes @ Value::Object(_)), Some(alert)) =
            (attributes_type, &push.attributes, &alert)
        else {
            return Err(ActivityRefusal::InvalidPayload);
        };
        if !within(attributes_type, MAX_ATTRIBUTES_TYPE_BYTES) {
            return Err(ActivityRefusal::InvalidPayload);
        }
        aps.insert("attributes-type".into(), json!(attributes_type));
        aps.insert("attributes".into(), attributes.clone());
        aps.insert("alert".into(), alert.clone());
    } else if let Some(alert) = alert {
        aps.insert("alert".into(), alert);
    }

    let body = serde_json::to_string(&json!({ "aps": aps })).map_err(|_| ActivityRefusal::InvalidPayload)?;
    if !within(&body, MAX_BODY_BYTES) {
        return Err(ActivityRefusal::InvalidPayload);
    }
    Ok(ActivityRequest { priority, expiration: stale, body })
}

/// A token bucket per activity token: a burst of five, then one a second.
///
/// Apple throttles Live Activity pushes per activity, and a push over its budget is dropped there
/// without telling anyone, so spending the budget here costs nothing a retry would not.
#[derive(Default)]
pub struct ActivityLimiter {
    buckets: HashMap<String, (f64, Instant)>,
}

impl ActivityLimiter {
    pub fn allow(&mut self, token: &str, now: Instant) -> bool {
        if !self.buckets.contains_key(token) && self.buckets.len() >= MAX_TRACKED_TOKENS {
            let refilled = Duration::from_secs_f64(BURST / REFILL_PER_SECOND);
            self.buckets.retain(|_, (_, last)| now.saturating_duration_since(*last) < refilled);
            if self.buckets.len() >= MAX_TRACKED_TOKENS {
                return false;
            }
        }
        let (tokens, last) = self.buckets.entry(token.to_owned()).or_insert((BURST, now));
        let elapsed = now.saturating_duration_since(*last).as_secs_f64();
        *tokens = (*tokens + elapsed * REFILL_PER_SECOND).min(BURST);
        *last = now;
        if *tokens >= 1.0 {
            *tokens -= 1.0;
            true
        } else {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: u64 = 1_800_000_000;

    fn push(event: ActivityEvent) -> ActivityPush {
        ActivityPush {
            activity_token: "ab".repeat(32),
            activity: ActivityKind::Session,
            event,
            content_state: json!({ "title": "Mac", "frames": 3 }),
            stale_seconds: None,
            priority: None,
            attributes_type: None,
            attributes: None,
            alert_title: None,
            alert_body: None,
            environment: None,
            dismissal_seconds: None,
            request_id: None,
        }
    }

    fn start() -> ActivityPush {
        ActivityPush {
            attributes_type: Some("SessionAttributes".into()),
            attributes: Some(json!({ "hostId": "MAC-1" })),
            alert_title: Some("Peering".into()),
            alert_body: Some("Session started".into()),
            ..push(ActivityEvent::Start)
        }
    }

    fn body(request: &ActivityRequest) -> Value {
        serde_json::from_str(&request.body).expect("valid JSON")
    }

    #[test]
    fn an_update_carries_state_and_a_timestamp_at_low_priority() {
        let request = build(&push(ActivityEvent::Update), NOW).unwrap();
        assert_eq!(request.priority, 5);
        assert_eq!(request.expiration, None);
        assert_eq!(
            body(&request),
            json!({ "aps": { "timestamp": NOW, "event": "update", "content-state": { "title": "Mac", "frames": 3 } } })
        );
    }

    #[test]
    fn an_update_with_staleness_sets_the_stale_date_and_the_expiration() {
        let request = build(&ActivityPush { stale_seconds: Some(90), ..push(ActivityEvent::Update) }, NOW).unwrap();
        assert_eq!(body(&request)["aps"]["stale-date"], NOW + 90);
        assert_eq!(request.expiration, Some(NOW + 90));
    }

    #[test]
    fn an_end_dismisses_four_hours_later_at_high_priority() {
        let request = build(&push(ActivityEvent::End), NOW).unwrap();
        assert_eq!(request.priority, 10);
        let aps = &body(&request)["aps"];
        assert_eq!(aps["event"], "end");
        assert_eq!(aps["dismissal-date"], NOW + 4 * 60 * 60);
    }

    #[test]
    fn an_end_with_dismissal_seconds_dismisses_that_much_later() {
        let end = ActivityPush { dismissal_seconds: Some(1800), ..push(ActivityEvent::End) };
        assert_eq!(body(&build(&end, NOW).unwrap())["aps"]["dismissal-date"], NOW + 1800);
    }

    #[test]
    fn dismissal_seconds_are_capped_at_four_hours() {
        let end = ActivityPush { dismissal_seconds: Some(u32::MAX), ..push(ActivityEvent::End) };
        assert_eq!(body(&build(&end, NOW).unwrap())["aps"]["dismissal-date"], NOW + 14_400);
    }

    #[test]
    fn zero_dismissal_seconds_dismisses_immediately() {
        let end = ActivityPush { dismissal_seconds: Some(0), ..push(ActivityEvent::End) };
        assert_eq!(body(&build(&end, NOW).unwrap())["aps"]["dismissal-date"], NOW);
    }

    #[test]
    fn dismissal_seconds_mean_nothing_to_an_update() {
        let update = ActivityPush { dismissal_seconds: Some(60), ..push(ActivityEvent::Update) };
        assert!(body(&build(&update, NOW).unwrap())["aps"].get("dismissal-date").is_none());
    }

    #[test]
    fn a_request_id_over_64_bytes_is_refused_and_64_is_accepted() {
        let long = ActivityPush { request_id: Some("a".repeat(65)), ..push(ActivityEvent::Update) };
        assert_eq!(build(&long, NOW), Err(ActivityRefusal::InvalidPayload));
        let fits = ActivityPush { request_id: Some("a".repeat(64)), ..push(ActivityEvent::Update) };
        assert!(build(&fits, NOW).is_ok());
    }

    #[test]
    fn a_message_from_a_host_without_either_new_field_still_parses() {
        let text = r#"{"type":"notifyActivity","activityToken":"0a1b","activity":"session","event":"end","contentState":{}}"#;
        let message: crate::protocol::ClientMessage = serde_json::from_str(text).expect("parses");
        let crate::protocol::ClientMessage::NotifyActivity(push) = message else { panic!("not a notifyActivity") };
        assert_eq!((push.dismissal_seconds, push.request_id), (None, None));
    }

    #[test]
    fn both_new_fields_parse_in_camel_case() {
        let text = r#"{"type":"notifyActivity","activityToken":"0a1b","activity":"session","event":"end","contentState":{},"dismissalSeconds":1800,"requestId":"r-1"}"#;
        let message: crate::protocol::ClientMessage = serde_json::from_str(text).expect("parses");
        let crate::protocol::ClientMessage::NotifyActivity(push) = message else { panic!("not a notifyActivity") };
        assert_eq!((push.dismissal_seconds, push.request_id.as_deref()), (Some(1800), Some("r-1")));
    }

    #[test]
    fn a_start_carries_attributes_and_an_alert() {
        let request = build(&start(), NOW).unwrap();
        assert_eq!(request.priority, 10);
        let aps = &body(&request)["aps"];
        assert_eq!(aps["event"], "start");
        assert_eq!(aps["attributes-type"], "SessionAttributes");
        assert_eq!(aps["attributes"], json!({ "hostId": "MAC-1" }));
        assert_eq!(aps["alert"], json!({ "title": "Peering", "body": "Session started" }));
        assert!(aps.get("dismissal-date").is_none());
    }

    #[test]
    fn a_start_missing_any_required_part_is_refused() {
        let cases = [
            ActivityPush { attributes_type: None, ..start() },
            ActivityPush { attributes: None, ..start() },
            ActivityPush { attributes: Some(json!("text")), ..start() },
            ActivityPush { alert_title: None, ..start() },
            ActivityPush { alert_body: None, ..start() },
            ActivityPush { attributes_type: Some(String::new()), ..start() },
        ];
        for case in cases {
            assert_eq!(build(&case, NOW), Err(ActivityRefusal::InvalidPayload));
        }
    }

    #[test]
    fn attributes_are_left_out_of_an_update() {
        let request = build(&ActivityPush { attributes: Some(json!({})), attributes_type: Some("X".into()), ..push(ActivityEvent::Update) }, NOW).unwrap();
        assert!(body(&request)["aps"].get("attributes").is_none());
        assert!(body(&request)["aps"].get("attributes-type").is_none());
    }

    #[test]
    fn an_alert_needs_both_halves_and_a_half_is_refused() {
        for event in [ActivityEvent::Update, ActivityEvent::End] {
            let title_only = ActivityPush { alert_title: Some("Only a title".into()), ..push(event) };
            assert_eq!(build(&title_only, NOW), Err(ActivityRefusal::InvalidPayload));
            let body_only = ActivityPush { alert_body: Some("Only a body".into()), ..push(event) };
            assert_eq!(build(&body_only, NOW), Err(ActivityRefusal::InvalidPayload));
        }
        assert!(body(&build(&push(ActivityEvent::Update), NOW).unwrap())["aps"].get("alert").is_none());
        let both = ActivityPush { alert_title: Some("T".into()), alert_body: Some("B".into()), ..push(ActivityEvent::Update) };
        assert_eq!(body(&build(&both, NOW).unwrap())["aps"]["alert"], json!({ "title": "T", "body": "B" }));
    }

    #[test]
    fn priority_may_be_overridden_to_five_or_ten_only() {
        assert_eq!(build(&ActivityPush { priority: Some(10), ..push(ActivityEvent::Update) }, NOW).unwrap().priority, 10);
        assert_eq!(build(&ActivityPush { priority: Some(5), ..push(ActivityEvent::End) }, NOW).unwrap().priority, 5);
        assert_eq!(build(&ActivityPush { priority: Some(7), ..push(ActivityEvent::Update) }, NOW), Err(ActivityRefusal::InvalidPayload));
    }

    #[test]
    fn content_state_must_be_an_object_within_the_size_cap() {
        for not_object in [json!([1]), json!("x"), json!(4), Value::Null] {
            let case = ActivityPush { content_state: not_object, ..push(ActivityEvent::Update) };
            assert_eq!(build(&case, NOW), Err(ActivityRefusal::InvalidPayload));
        }
        let filler = |len: usize| json!({ "k": "x".repeat(len) });
        let overhead = serde_json::to_string(&filler(0)).unwrap().len();
        let fits = ActivityPush { content_state: filler(MAX_CONTENT_STATE_BYTES - overhead), ..push(ActivityEvent::Update) };
        assert!(build(&fits, NOW).is_ok());
        let over = ActivityPush { content_state: filler(MAX_CONTENT_STATE_BYTES - overhead + 1), ..push(ActivityEvent::Update) };
        assert_eq!(build(&over, NOW), Err(ActivityRefusal::InvalidPayload));
    }

    #[test]
    fn a_whole_payload_over_apples_limit_is_refused() {
        let case = ActivityPush {
            content_state: json!({ "k": "x".repeat(3000) }),
            attributes: Some(json!({ "k": "y".repeat(1500) })),
            ..start()
        };
        assert_eq!(build(&case, NOW), Err(ActivityRefusal::InvalidPayload));
    }

    #[test]
    fn a_token_that_is_not_hex_or_is_empty_is_an_invalid_token() {
        for token in ["", "xyz", "abc", &"ab".repeat(200)] {
            let case = ActivityPush { activity_token: token.into(), ..push(ActivityEvent::Update) };
            assert_eq!(build(&case, NOW), Err(ActivityRefusal::InvalidToken), "{token:?}");
        }
    }

    #[test]
    fn apns_reasons_for_a_dead_token_are_told_apart_from_the_rest() {
        for (status, reason) in [(400, "BadDeviceToken"), (410, "Unregistered"), (410, "ExpiredToken"), (400, "DeviceTokenNotForTopic")] {
            let refusal = ApnsRefusal { status, reason: Some(reason.into()) };
            assert_eq!(ActivityFailure::from_refusal(&refusal), ActivityFailure::TokenRejected);
        }
        let throttle = ApnsRefusal { status: 429, reason: Some("TooManyRequests".into()) };
        assert_eq!(ActivityFailure::from_refusal(&throttle), ActivityFailure::Throttled);
        assert_eq!(ActivityFailure::Throttled.refusal(), ActivityRefusal::Unavailable);
        let outage = ApnsRefusal { status: 503, reason: None };
        assert_eq!(ActivityFailure::from_refusal(&outage), ActivityFailure::Unavailable);
        let too_big = ApnsRefusal { status: 413, reason: Some("PayloadTooLarge".into()) };
        assert_eq!(ActivityFailure::from_refusal(&too_big), ActivityFailure::Rejected);
        assert_eq!(ActivityFailure::TokenRejected.refusal(), ActivityRefusal::InvalidToken);
    }

    #[test]
    fn the_limiter_allows_a_burst_of_five_then_one_a_second() {
        let start = Instant::now();
        let mut limiter = ActivityLimiter::default();
        let sent = (0..8).filter(|_| limiter.allow("t", start)).count();
        assert_eq!(sent, 5);
        assert!(!limiter.allow("t", start + Duration::from_millis(900)));
        assert!(limiter.allow("t", start + Duration::from_millis(1000)));
        assert!(!limiter.allow("t", start + Duration::from_millis(1100)));
    }

    #[test]
    fn the_limiter_budgets_each_token_separately() {
        let start = Instant::now();
        let mut limiter = ActivityLimiter::default();
        for _ in 0..5 {
            assert!(limiter.allow("a", start));
        }
        assert!(!limiter.allow("a", start));
        assert!(limiter.allow("b", start));
    }

    #[test]
    fn the_limiter_refuses_new_tokens_past_its_table_until_old_ones_refill() {
        let start = Instant::now();
        let mut limiter = ActivityLimiter::default();
        for n in 0..MAX_TRACKED_TOKENS {
            assert!(limiter.allow(&format!("t{n}"), start));
        }
        assert!(!limiter.allow("one-more", start));
        assert!(limiter.allow("one-more", start + Duration::from_secs(10)));
    }

    #[test]
    fn a_swift_style_message_parses_and_survives_a_round_trip() {
        let text = r#"{"type":"notifyActivity","activityToken":"0a1b2c","activity":"agentChat","event":"update","contentState":{"status":"running","progress":0.5,"lines":["a","b"]},"staleSeconds":120,"priority":10,"environment":"sandbox","alertTitle":"Done","alertBody":"Finished"}"#;
        let message: crate::protocol::ClientMessage = serde_json::from_str(text).expect("parses");
        let crate::protocol::ClientMessage::NotifyActivity(push) = &message else { panic!("wrong variant") };
        assert_eq!(push.activity, ActivityKind::AgentChat);
        assert_eq!(push.event, ActivityEvent::Update);
        assert_eq!(push.stale_seconds, Some(120));
        assert_eq!(push.priority, Some(10));
        assert_eq!(push.environment, Some(ActivityEnvironment::Sandbox));
        assert_eq!(push.content_state["lines"][1], "b");
        let again: crate::protocol::ClientMessage = serde_json::from_str(&serde_json::to_string(&message).unwrap()).unwrap();
        assert_eq!(again, message);
    }

    #[test]
    fn optional_fields_may_be_absent_and_unknown_kinds_do_not_parse() {
        let minimal = r#"{"type":"notifyActivity","activityToken":"0a","activity":"terminal","event":"end","contentState":{}}"#;
        assert!(serde_json::from_str::<crate::protocol::ClientMessage>(minimal).is_ok());
        let unknown = minimal.replace("terminal", "pizza");
        assert!(serde_json::from_str::<crate::protocol::ClientMessage>(&unknown).is_err());
    }

    #[test]
    fn a_request_id_is_limited_by_characters_not_bytes() {
        let sixty_four_characters = "é".repeat(64);
        let fits = ActivityPush { request_id: Some(sixty_four_characters), ..push(ActivityEvent::Update) };
        assert!(build(&fits, NOW).is_ok());
        let too_long = ActivityPush { request_id: Some("é".repeat(65)), ..push(ActivityEvent::Update) };
        assert_eq!(build(&too_long, NOW), Err(ActivityRefusal::InvalidPayload));
    }

    #[test]
    fn an_undecodable_notify_activity_is_refused_with_its_request_id() {
        let cases = [
            r#"{"type":"notifyActivity","activityToken":"ab","activity":"session","event":"update","contentState":{},"priority":300,"requestId":"r1"}"#,
            r#"{"type":"notifyActivity","activityToken":"ab","activity":"session","event":"update","contentState":{},"staleSeconds":-5,"requestId":"r1"}"#,
            r#"{"type":"notifyActivity","activityToken":"ab","activity":"session","event":"explode","contentState":{},"requestId":"r1"}"#,
        ];
        for text in cases {
            assert!(serde_json::from_str::<crate::protocol::ClientMessage>(text).is_err(), "{text}");
            assert_eq!(refusal_for_undecodable(text), Some((ActivityRefusal::InvalidPayload, Some("r1".into()))));
        }
    }

    #[test]
    fn an_undecodable_notify_activity_without_a_readable_request_id_is_still_refused() {
        let text = r#"{"type":"notifyActivity","event":"explode","requestId":7}"#;
        assert_eq!(refusal_for_undecodable(text), Some((ActivityRefusal::InvalidPayload, None)));
        let long = format!(r#"{{"type":"notifyActivity","requestId":"{}"}}"#, "x".repeat(65));
        assert_eq!(refusal_for_undecodable(&long), Some((ActivityRefusal::InvalidPayload, None)));
    }

    #[test]
    fn other_undecodable_messages_are_not_taken_for_activity_pushes() {
        assert_eq!(refusal_for_undecodable(r#"{"type":"nonsense"}"#), None);
        assert_eq!(refusal_for_undecodable("not json"), None);
        assert_eq!(refusal_for_undecodable(r#"{"requestId":"r"}"#), None);
    }
}
