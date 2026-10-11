use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use super::*;
use crate::fcm::FakeAccessTokens;
use crate::quota::Plan;

const PACKAGE: &str = "pl.dmq.peering";
const YEAR: &str = "pl.dmq.peering.pro.year";
const LIFETIME: &str = "pl.dmq.peering.pro.lifetime1";
/// Ends at 2025-06-01T10:00:00Z.
const EXPIRY: u64 = 1_748_772_000;
/// SHA-256 of the three bytes "abc", the device key the binding tests use as `616263`.
const ABC_DIGEST: &str = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

const SUBSCRIPTION_SAMPLE: &str = r#"{
  "kind": "androidpublisher#subscriptionPurchaseV2",
  "startTime": "2024-06-01T10:00:00.000Z",
  "regionCode": "US",
  "subscriptionState": "SUBSCRIPTION_STATE_ACTIVE",
  "latestOrderId": "GPA.3333-4444-5555-66666",
  "lineItems": [
    {
      "productId": "pl.dmq.peering.pro.year",
      "expiryTime": "2025-06-01T10:00:00.123Z",
      "autoRenewingPlan": {"autoRenewEnabled": true}
    }
  ],
  "acknowledgementState": "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED",
  "externalAccountIdentifiers": {
    "externalAccountId": "user-1",
    "obfuscatedExternalAccountId": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  }
}"#;

const ONE_TIME_SAMPLE: &str = r#"{
  "kind": "androidpublisher#productPurchase",
  "purchaseTimeMillis": "1717236000000",
  "purchaseState": 0,
  "consumptionState": 0,
  "acknowledgementState": 1,
  "orderId": "GPA.1111-2222-3333-44444",
  "purchaseType": 0,
  "obfuscatedExternalAccountId": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  "quantity": 1,
  "regionCode": "US"
}"#;

fn subscription_with_state(state: &str) -> String {
    SUBSCRIPTION_SAMPLE.replace("SUBSCRIPTION_STATE_ACTIVE", state)
}

fn purchase(state: PurchaseState, expiry_unix: Option<u64>, is_lifetime: bool) -> PlayPurchase {
    PlayPurchase {
        product_id: YEAR.to_owned(),
        state,
        expiry_unix,
        obfuscated_account_id: None,
        is_lifetime,
    }
}

#[test]
fn the_subscription_sample_reads_as_an_active_expiring_purchase() {
    let parsed = parse::purchase(YEAR, false, SUBSCRIPTION_SAMPLE).expect("parses");
    assert_eq!(parsed.product_id, YEAR);
    assert_eq!(parsed.state, PurchaseState::Active);
    assert_eq!(parsed.expiry_unix, Some(EXPIRY));
    assert_eq!(parsed.obfuscated_account_id.as_deref(), Some(ABC_DIGEST));
    assert!(!parsed.is_lifetime);
}

#[test]
fn every_subscription_state_has_a_meaning() {
    let cases = [
        ("SUBSCRIPTION_STATE_IN_GRACE_PERIOD", PurchaseState::InGrace),
        ("SUBSCRIPTION_STATE_CANCELED", PurchaseState::Canceled),
        ("SUBSCRIPTION_STATE_ON_HOLD", PurchaseState::OnHold),
        ("SUBSCRIPTION_STATE_PAUSED", PurchaseState::Paused),
        ("SUBSCRIPTION_STATE_EXPIRED", PurchaseState::Expired),
        ("SUBSCRIPTION_STATE_PENDING", PurchaseState::Pending),
        ("SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED", PurchaseState::Pending),
    ];
    for (name, expected) in cases {
        let parsed = parse::purchase(YEAR, false, &subscription_with_state(name)).expect(name);
        assert_eq!(parsed.state, expected, "{name}");
    }
}

#[test]
fn an_unknown_subscription_state_is_refused() {
    assert!(parse::purchase(YEAR, false, &subscription_with_state("SUBSCRIPTION_STATE_SOMETIME")).is_err());
}

#[test]
fn a_subscription_reply_without_the_product_is_refused() {
    let body = SUBSCRIPTION_SAMPLE.replace("pl.dmq.peering.pro.year", "pl.dmq.peering.relay.hour");
    assert!(parse::purchase(YEAR, false, &body).is_err());
}

#[test]
fn a_subscription_without_an_expiry_has_none() {
    let body = SUBSCRIPTION_SAMPLE.replace(r#""expiryTime": "2025-06-01T10:00:00.123Z","#, "");
    let parsed = parse::purchase(YEAR, false, &body).expect("parses");
    assert_eq!(parsed.expiry_unix, None);
}

#[test]
fn the_one_time_sample_reads_as_a_lifetime_purchase_with_no_expiry() {
    let parsed = parse::purchase(LIFETIME, true, ONE_TIME_SAMPLE).expect("parses");
    assert_eq!(parsed.product_id, LIFETIME);
    assert_eq!(parsed.state, PurchaseState::Active);
    assert_eq!(parsed.expiry_unix, None);
    assert_eq!(parsed.obfuscated_account_id.as_deref(), Some(ABC_DIGEST));
    assert!(parsed.is_lifetime);
}

#[test]
fn one_time_purchase_states_are_zero_purchased_one_cancelled_two_pending() {
    let with_state = |n: u32| ONE_TIME_SAMPLE.replace("\"purchaseState\": 0", &format!("\"purchaseState\": {n}"));
    assert_eq!(parse::purchase(LIFETIME, true, &with_state(1)).unwrap().state, PurchaseState::Canceled);
    assert_eq!(parse::purchase(LIFETIME, true, &with_state(2)).unwrap().state, PurchaseState::Pending);
    assert!(parse::purchase(LIFETIME, true, &with_state(7)).is_err());
    let missing = ONE_TIME_SAMPLE.replace("\"purchaseState\": 0,", "");
    assert!(parse::purchase(LIFETIME, true, &missing).is_err());
}

#[test]
fn the_expiry_is_read_as_utc_and_the_fraction_is_dropped() {
    assert_eq!(parse::rfc3339_unix("2025-01-01T00:00:00Z"), Some(1_735_689_600));
    assert_eq!(parse::rfc3339_unix("2025-01-01T00:00:00.999999Z"), Some(1_735_689_600));
    assert_eq!(parse::rfc3339_unix("2024-02-29T12:00:00Z"), Some(1_709_208_000));
}

#[test]
fn a_time_that_is_not_utc_or_not_a_time_is_refused() {
    assert_eq!(parse::rfc3339_unix("2025-01-01T00:00:00+01:00"), None);
    assert_eq!(parse::rfc3339_unix("2025-01-01"), None);
    assert_eq!(parse::rfc3339_unix("2025-13-01T00:00:00Z"), None);
    assert_eq!(parse::rfc3339_unix("not a time"), None);
}

#[test]
fn a_live_subscription_buys_its_plan() {
    let verdict = verdict(&purchase(PurchaseState::Active, Some(2_000), false), YEAR, None, 1_000);
    assert_eq!(verdict, PlayVerdict::Active(Plan::Pro));
}

#[test]
fn a_subscription_is_live_until_its_expiry_and_not_at_it() {
    let before = purchase(PurchaseState::Active, Some(2_000), false);
    assert_eq!(verdict(&before, YEAR, None, 1_999), PlayVerdict::Active(Plan::Pro));
    assert_eq!(verdict(&before, YEAR, None, 2_000), PlayVerdict::Rejected(PlayRejection::Expired));
}

#[test]
fn a_cancelled_subscription_keeps_its_access_until_the_expiry() {
    let cancelled = purchase(PurchaseState::Canceled, Some(2_000), false);
    assert_eq!(verdict(&cancelled, YEAR, None, 1_000), PlayVerdict::Active(Plan::Pro));
    assert_eq!(verdict(&cancelled, YEAR, None, 3_000), PlayVerdict::Rejected(PlayRejection::Expired));
}

#[test]
fn a_subscription_in_grace_is_live() {
    let grace = purchase(PurchaseState::InGrace, Some(2_000), false);
    assert_eq!(verdict(&grace, YEAR, None, 1_000), PlayVerdict::Active(Plan::Pro));
}

#[test]
fn on_hold_and_paused_and_expired_subscriptions_are_expired() {
    for state in [PurchaseState::OnHold, PurchaseState::Paused, PurchaseState::Expired] {
        assert_eq!(
            verdict(&purchase(state, Some(2_000), false), YEAR, None, 1_000),
            PlayVerdict::Rejected(PlayRejection::Expired),
            "{state:?}"
        );
    }
}

#[test]
fn a_pending_purchase_is_not_a_purchase() {
    let pending = purchase(PurchaseState::Pending, Some(2_000), false);
    assert_eq!(verdict(&pending, YEAR, None, 1_000), PlayVerdict::Rejected(PlayRejection::NotAPurchase));
}

#[test]
fn a_subscription_with_no_expiry_cannot_be_read_and_is_unavailable() {
    let no_expiry = purchase(PurchaseState::Active, None, false);
    assert_eq!(verdict(&no_expiry, YEAR, None, 1_000), PlayVerdict::Rejected(PlayRejection::Unavailable));
}

#[test]
fn a_lifetime_purchase_is_live_without_an_expiry() {
    let mut lifetime = purchase(PurchaseState::Active, None, true);
    lifetime.product_id = LIFETIME.to_owned();
    assert_eq!(verdict(&lifetime, LIFETIME, None, u64::MAX), PlayVerdict::Active(Plan::Pro));
}

#[test]
fn a_cancelled_lifetime_purchase_is_not_a_purchase() {
    let mut cancelled = purchase(PurchaseState::Canceled, None, true);
    cancelled.product_id = LIFETIME.to_owned();
    assert_eq!(verdict(&cancelled, LIFETIME, None, 1_000), PlayVerdict::Rejected(PlayRejection::NotAPurchase));
}

#[test]
fn a_relay_product_buys_relay() {
    let relay = "pl.dmq.peering.relay.hour";
    let mut purchase = purchase(PurchaseState::Active, Some(2_000), false);
    purchase.product_id = relay.to_owned();
    assert_eq!(verdict(&purchase, relay, None, 1_000), PlayVerdict::Active(Plan::Relay));
}

#[test]
fn a_product_this_relay_does_not_sell_is_refused() {
    let unknown = "pl.dmq.peering.plus.monthly";
    let mut purchase = purchase(PurchaseState::Active, Some(2_000), false);
    purchase.product_id = unknown.to_owned();
    assert_eq!(verdict(&purchase, unknown, None, 1_000), PlayVerdict::Rejected(PlayRejection::UnknownProduct));
}

#[test]
fn a_purchase_for_another_product_than_the_one_asked_is_refused() {
    let live = purchase(PurchaseState::Active, Some(2_000), false);
    assert_eq!(
        verdict(&live, "pl.dmq.peering.pro.monthly", None, 1_000),
        PlayVerdict::Rejected(PlayRejection::UnknownProduct)
    );
}

#[test]
fn a_client_whose_key_hashes_to_the_purchase_account_is_bound_to_it() {
    let mut bound = purchase(PurchaseState::Active, Some(2_000), false);
    bound.obfuscated_account_id = Some(ABC_DIGEST.to_owned());
    assert_eq!(verdict(&bound, YEAR, Some("616263"), 1_000), PlayVerdict::Active(Plan::Pro));
}

#[test]
fn a_different_device_key_is_a_wrong_device() {
    let mut bound = purchase(PurchaseState::Active, Some(2_000), false);
    bound.obfuscated_account_id = Some(ABC_DIGEST.to_owned());
    assert_eq!(verdict(&bound, YEAR, Some("616264"), 1_000), PlayVerdict::Rejected(PlayRejection::WrongDevice));
}

#[test]
fn a_purchase_with_no_account_id_is_not_bound_to_a_proven_device() {
    let unbound = purchase(PurchaseState::Active, Some(2_000), false);
    assert_eq!(verdict(&unbound, YEAR, Some("616263"), 1_000), PlayVerdict::Rejected(PlayRejection::WrongDevice));
}

#[test]
fn a_key_that_is_not_hex_is_a_wrong_device() {
    let mut bound = purchase(PurchaseState::Active, Some(2_000), false);
    bound.obfuscated_account_id = Some(ABC_DIGEST.to_owned());
    assert_eq!(verdict(&bound, YEAR, Some("not hex"), 1_000), PlayVerdict::Rejected(PlayRejection::WrongDevice));
}

#[test]
fn sha256_matches_the_published_vector() {
    assert_eq!(sha256_hex(b"abc"), ABC_DIGEST);
}

#[test]
fn the_purchase_url_for_a_subscription_names_the_v2_endpoint() {
    assert_eq!(
        purchase_url(PACKAGE, YEAR, "tok"),
        "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/pl.dmq.peering/purchases/subscriptionsv2/tokens/tok"
    );
}

#[test]
fn the_purchase_url_for_lifetime_names_the_product_endpoint() {
    assert_eq!(
        purchase_url(PACKAGE, LIFETIME, "tok"),
        "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/pl.dmq.peering/purchases/products/pl.dmq.peering.pro.lifetime1/tokens/tok"
    );
}

#[test]
fn a_token_cannot_change_the_path_it_is_put_in() {
    let url = purchase_url(PACKAGE, YEAR, "a/b?c=d+e%f");
    assert!(url.ends_with("/tokens/a%2Fb%3Fc%3Dd%2Be%25f"), "{url}");
}

#[test]
fn an_unreserved_token_is_left_as_it_is() {
    assert!(purchase_url(PACKAGE, YEAR, "AZaz09-._~").ends_with("/tokens/AZaz09-._~"));
}

/// Records the URL and bearer it was asked for, and answers with one fixed reply.
struct RecordingTransport {
    status: u16,
    body: String,
    asked: Arc<Mutex<Vec<(String, String)>>>,
}

impl PlayTransport for RecordingTransport {
    fn get<'a>(&'a self, url: &'a str, bearer: &'a str) -> BoxFuture<'a, Result<HttpsReply, BoxError>> {
        self.asked.lock().unwrap().push((url.to_owned(), bearer.to_owned()));
        let reply = HttpsReply { status: self.status, body: self.body.clone() };
        Box::pin(async move { Ok(reply) })
    }
}

fn api_answering(status: u16, body: &str) -> (GooglePlayApi, Arc<Mutex<Vec<(String, String)>>>) {
    let asked = Arc::new(Mutex::new(Vec::new()));
    let transport = RecordingTransport { status, body: body.to_owned(), asked: Arc::clone(&asked) };
    (GooglePlayApi::new(FakeAccessTokens::giving("ya29.play"), transport), asked)
}

#[tokio::test]
async fn a_lookup_asks_the_endpoint_with_the_bearer_and_reads_the_reply() {
    let (api, asked) = api_answering(200, SUBSCRIPTION_SAMPLE);
    let purchase = api.purchase_state(PACKAGE, YEAR, "tok").await.expect("reads");
    assert_eq!(purchase.state, PurchaseState::Active);

    let asked = asked.lock().unwrap();
    assert_eq!(asked.len(), 1);
    assert!(asked[0].0.ends_with("/subscriptionsv2/tokens/tok"));
    assert_eq!(asked[0].1, "ya29.play");
}

#[tokio::test]
async fn a_refused_lookup_is_an_error() {
    let (api, _) = api_answering(404, r#"{"error":"not found"}"#);
    assert!(api.purchase_state(PACKAGE, YEAR, "tok").await.is_err());
}

#[tokio::test]
async fn a_reply_that_is_not_a_purchase_is_an_error() {
    let (api, _) = api_answering(200, "<html>");
    assert!(api.purchase_state(PACKAGE, YEAR, "tok").await.is_err());
}

/// Answers with one purchase and counts how often Google was asked.
struct CountingPlayApi {
    calls: Arc<AtomicUsize>,
    answer: PlayPurchase,
}

impl PlayApi for CountingPlayApi {
    fn purchase_state<'a>(&'a self, _: &'a str, _: &'a str, _: &'a str) -> BoxFuture<'a, Result<PlayPurchase, BoxError>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let answer = self.answer.clone();
        Box::pin(async move { Ok(answer) })
    }
}

/// Never answers, so only the verifier's timeout can end the lookup.
struct NeverAnswers;

impl PlayApi for NeverAnswers {
    fn purchase_state<'a>(&'a self, _: &'a str, _: &'a str, _: &'a str) -> BoxFuture<'a, Result<PlayPurchase, BoxError>> {
        Box::pin(std::future::pending())
    }
}

fn live_pro_year() -> PlayPurchase {
    parse::purchase(YEAR, false, SUBSCRIPTION_SAMPLE).expect("the sample parses")
}

#[tokio::test]
async fn a_live_purchase_is_verified_as_pro() {
    let verifier = PlayVerifier::new(PACKAGE.into(), FakePlayApi::answering(live_pro_year()));
    let mut cache = PlayReceiptCache::default();
    let verdict = verifier.verdict(&mut cache, YEAR, "tok", None, EXPIRY - 1).await;
    assert_eq!(verdict, PlayVerdict::Active(Plan::Pro));
}

#[tokio::test]
async fn google_is_asked_once_per_purchase_for_a_session() {
    let calls = Arc::new(AtomicUsize::new(0));
    let api = CountingPlayApi { calls: Arc::clone(&calls), answer: live_pro_year() };
    let verifier = PlayVerifier::new(PACKAGE.into(), api);
    let mut cache = PlayReceiptCache::default();
    verifier.verdict(&mut cache, YEAR, "tok", None, EXPIRY - 1).await;
    verifier.verdict(&mut cache, YEAR, "tok", None, EXPIRY - 1).await;
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn the_same_purchase_for_another_device_is_asked_again() {
    let calls = Arc::new(AtomicUsize::new(0));
    let api = CountingPlayApi { calls: Arc::clone(&calls), answer: live_pro_year() };
    let verifier = PlayVerifier::new(PACKAGE.into(), api);
    let mut cache = PlayReceiptCache::default();
    verifier.verdict(&mut cache, YEAR, "tok", Some("616263"), EXPIRY - 1).await;
    verifier.verdict(&mut cache, YEAR, "tok", Some("616264"), EXPIRY - 1).await;
    assert_eq!(calls.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn a_failed_lookup_is_unavailable_and_so_free() {
    let verifier = PlayVerifier::new(PACKAGE.into(), FakePlayApi::failing("status 500"));
    let mut cache = PlayReceiptCache::default();
    let verdict = verifier.verdict(&mut cache, YEAR, "tok", None, EXPIRY - 1).await;
    assert_eq!(verdict, PlayVerdict::Rejected(PlayRejection::Unavailable));
}

#[tokio::test]
async fn a_lookup_that_never_answers_is_unavailable_at_the_timeout() {
    let verifier = PlayVerifier::with_timeout(PACKAGE.into(), NeverAnswers, Duration::from_millis(10));
    let mut cache = PlayReceiptCache::default();
    let verdict = verifier.verdict(&mut cache, YEAR, "tok", None, EXPIRY - 1).await;
    assert_eq!(verdict, PlayVerdict::Rejected(PlayRejection::Unavailable));
}
