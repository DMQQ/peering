//! Asks Google Play whether a purchase is live, and turns the answer into a `PlayVerdict`.
//!
//! Two endpoints of the Google Play Developer API v3 (`androidpublisher.googleapis.com`):
//! `purchases.subscriptionsv2.get` for subscriptions, and `purchases.products.get` for one-time
//! products, which is how the Lifetime purchase is read. Both are authorised with a service account
//! token that carries the `androidpublisher` scope.
//!
//! **Needs the owner's Google credentials to run live.** The relay needs a service account that has
//! been granted access to the app's purchase data in Play Console, and its JSON file named by
//! `PEERINGD_PLAY_SERVICE_ACCOUNT`. Nothing in the tests reaches Google: the parsing is tested on
//! saved samples and the network is behind `PlayTransport`.
//!
//! **UNVERIFIED against current Google documentation.** The endpoint paths, the field names
//! (`subscriptionState`, `lineItems`, `expiryTime`, `externalAccountIdentifiers`,
//! `obfuscatedExternalAccountId`, `purchaseState`) and the state strings were written from memory of
//! the v3 reference and have not been checked against a live response. Confirm each one on the first
//! real purchase lookup before relying on the verdict.
//!
//! **Device binding is a hash, and the app must match it.** When the client has proved its device
//! key, the purchase must carry as its obfuscated account id the lowercase SHA-256 hex of the 65-byte
//! public key. The Android client has to set that value when it starts the purchase, and nothing in
//! this relay can check that it does.

mod parse;
#[cfg(test)]
mod tests;

use std::collections::HashMap;
use std::fmt;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use ring::digest::{SHA256, digest};

use crate::fcm::https::{self, HttpsReply};
use crate::fcm::{AccessTokens, BoxFuture};
use crate::fcm_auth::{AccessTokenCache, BoxError, HttpTokenExchange, ServiceAccount, SystemClock};
use crate::playbilling::{PlayProduct, PlayReceiptCache, PlayRejection, PlayVerdict};
use crate::protocol::hex_bytes;
use tracing::warn;

pub const ANDROID_PUBLISHER_SCOPE: &str = "https://www.googleapis.com/auth/androidpublisher";
const API_ORIGIN: &str = "https://androidpublisher.googleapis.com/androidpublisher/v3";
/// A 65 byte uncompressed P-256 point, as hex.
const MAX_CLIENT_KEY_HEX: usize = 130;
/// How long Google gets to answer before the purchase is treated as unverifiable.
pub const PLAY_TIMEOUT: Duration = Duration::from_secs(2);
/// How long a verdict that was good when Google last answered may stand in for Google being down.
const STALE_IF_ERROR: Duration = Duration::from_secs(24 * 60 * 60);
const MAX_REMEMBERED_VERDICTS: usize = 1024;

/// Google answered, and the answer is final: this purchase is not there to be read. Anything else
/// that goes wrong (a timeout, a 5xx, a dropped socket) says nothing about the purchase.
#[derive(Debug)]
struct LookupRefused(u16);

impl fmt::Display for LookupRefused {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Google Play refused the purchase lookup with status {}", self.0)
    }
}

impl std::error::Error for LookupRefused {}

fn is_final_refusal(status: u16) -> bool {
    (400..500).contains(&status) && !matches!(status, 408 | 429)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PurchaseState {
    Active,
    InGrace,
    /// The subscriber cancelled and keeps access until the expiry. For a one-time purchase, the
    /// purchase itself was cancelled before it completed.
    Canceled,
    OnHold,
    Paused,
    Expired,
    Pending,
}

/// What Google reported about one purchase token, for the product it was asked about.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlayPurchase {
    pub product_id: String,
    pub state: PurchaseState,
    /// Unix seconds. Absent for a one-time purchase, which does not expire.
    pub expiry_unix: Option<u64>,
    pub obfuscated_account_id: Option<String>,
    pub is_lifetime: bool,
}

/// Reads one purchase from Google. The live implementation is `GooglePlayApi`; tests use fakes.
pub trait PlayApi: Send + Sync {
    fn purchase_state<'a>(
        &'a self,
        package: &'a str,
        product_id: &'a str,
        token: &'a str,
    ) -> BoxFuture<'a, Result<PlayPurchase, BoxError>>;
}

/// The one HTTP call the Play client makes: a GET with a bearer token.
pub trait PlayTransport: Send + Sync {
    fn get<'a>(&'a self, url: &'a str, bearer: &'a str) -> BoxFuture<'a, Result<HttpsReply, BoxError>>;
}

pub struct HttpsPlayTransport {
    tls: Arc<tokio_rustls::rustls::ClientConfig>,
}

impl PlayTransport for HttpsPlayTransport {
    fn get<'a>(&'a self, url: &'a str, bearer: &'a str) -> BoxFuture<'a, Result<HttpsReply, BoxError>> {
        Box::pin(async move {
            let authorization = format!("Bearer {bearer}");
            https::request(
                &self.tls,
                http::Method::GET,
                url,
                &[("authorization", authorization.as_str())],
                bytes::Bytes::new(),
            )
            .await
        })
    }
}

pub struct GooglePlayApi {
    tokens: Box<dyn AccessTokens>,
    transport: Box<dyn PlayTransport>,
}

impl GooglePlayApi {
    pub fn new(tokens: impl AccessTokens + 'static, transport: impl PlayTransport + 'static) -> Self {
        Self { tokens: Box::new(tokens), transport: Box::new(transport) }
    }

    /// The client the relay runs with: a token minted from the service account file, sent over HTTPS.
    pub fn from_service_account_file(path: &Path) -> Result<Self, BoxError> {
        let account = ServiceAccount::from_file(path)?;
        let tls = https::tls_config()?;
        let exchange = HttpTokenExchange::new(account.token_uri().to_owned(), Arc::clone(&tls));
        let tokens = AccessTokenCache::new(account, ANDROID_PUBLISHER_SCOPE, exchange, SystemClock);
        Ok(Self::new(tokens, HttpsPlayTransport { tls }))
    }
}

impl PlayApi for GooglePlayApi {
    fn purchase_state<'a>(
        &'a self,
        package: &'a str,
        product_id: &'a str,
        token: &'a str,
    ) -> BoxFuture<'a, Result<PlayPurchase, BoxError>> {
        Box::pin(async move {
            let bearer = self.tokens.token().await?;
            let url = purchase_url(package, product_id, token);
            let reply = self.transport.get(&url, &bearer).await?;
            if reply.status != 200 {
                return Err(BoxError::from(LookupRefused(reply.status)));
            }
            parse::purchase(product_id, is_one_time(product_id), &reply.body)
        })
    }
}

/// Decides a connect's plan from the Play purchase it presents.
///
/// Asks Google at most once per purchase per session, and fails closed: an error, a timeout, or a
/// session that has spent its budget is `Unavailable`, which meters as free.
pub struct PlayVerifier {
    package: String,
    api: Box<dyn PlayApi>,
    timeout: Duration,
    /// The last good verdict per purchase for the whole process, so a Google outage does not
    /// demote every paying client to free as its socket reconnects.
    last_good: Mutex<HashMap<VerdictKey, GoodVerdict>>,
}

/// Purchase token, product, and the device key the verdict was bound to.
type VerdictKey = (String, String, Option<String>);

#[derive(Clone, Copy)]
struct GoodVerdict {
    verdict: PlayVerdict,
    at: Instant,
    expiry_unix: Option<u64>,
}

impl PlayVerifier {
    pub fn new(package: String, api: impl PlayApi + 'static) -> Self {
        Self::with_timeout(package, api, PLAY_TIMEOUT)
    }

    pub fn with_timeout(package: String, api: impl PlayApi + 'static, timeout: Duration) -> Self {
        Self { package, api: Box::new(api), timeout, last_good: Mutex::new(HashMap::new()) }
    }

    pub fn from_service_account_file(package: String, path: &Path) -> Result<Self, BoxError> {
        Ok(Self::new(package, GooglePlayApi::from_service_account_file(path)?))
    }

    /// The verdict on one purchase. `client_key` is the device key once its proof has verified.
    pub async fn verdict(
        &self,
        cache: &mut PlayReceiptCache,
        product_id: &str,
        purchase_token: &str,
        client_key: Option<&str>,
        now: u64,
    ) -> PlayVerdict {
        if let Some(seen) = cache.seen(purchase_token, product_id, client_key) {
            return seen;
        }
        if !cache.can_check() {
            return PlayVerdict::Rejected(PlayRejection::Unavailable);
        }
        let verdict = self.ask(product_id, purchase_token, client_key, now).await;
        cache.record(purchase_token, product_id, client_key, verdict);
        verdict
    }

    async fn ask(&self, product_id: &str, purchase_token: &str, client_key: Option<&str>, now: u64) -> PlayVerdict {
        let lookup = self.api.purchase_state(&self.package, product_id, purchase_token);
        let key = (purchase_token.to_owned(), product_id.to_owned(), client_key.map(str::to_owned));
        match tokio::time::timeout(self.timeout, lookup).await {
            Ok(Ok(purchase)) => {
                let verdict = verdict(&purchase, product_id, client_key, now);
                self.remember(key, verdict, purchase.expiry_unix);
                verdict
            }
            Ok(Err(error)) => {
                warn!(error = %error, "Play purchase lookup failed");
                if error.downcast_ref::<LookupRefused>().is_some_and(|refused| is_final_refusal(refused.0)) {
                    self.last_good.lock().unwrap().remove(&key);
                    return PlayVerdict::Rejected(PlayRejection::Unavailable);
                }
                self.stale_or_unavailable(&key, now)
            }
            Err(_) => {
                warn!("Play purchase lookup timed out");
                self.stale_or_unavailable(&key, now)
            }
        }
    }

    fn remember(&self, key: VerdictKey, verdict: PlayVerdict, expiry_unix: Option<u64>) {
        let mut last_good = self.last_good.lock().unwrap();
        match verdict {
            PlayVerdict::Active(_) => {
                if last_good.len() >= MAX_REMEMBERED_VERDICTS && !last_good.contains_key(&key) {
                    last_good.clear();
                }
                last_good.insert(key, GoodVerdict { verdict, at: Instant::now(), expiry_unix });
            }
            PlayVerdict::Rejected(_) => {
                last_good.remove(&key);
            }
        }
    }

    fn stale_or_unavailable(&self, key: &VerdictKey, now: u64) -> PlayVerdict {
        let held = self.last_good.lock().unwrap().get(key).copied();
        match held {
            Some(good) if good.at.elapsed() < STALE_IF_ERROR && good.expiry_unix.is_none_or(|expiry| expiry > now) => {
                warn!("Play lookup failed, serving the last good verdict");
                good.verdict
            }
            _ => PlayVerdict::Rejected(PlayRejection::Unavailable),
        }
    }
}

/// Lifetime is the one-time product; the others are subscriptions.
pub fn is_one_time(product_id: &str) -> bool {
    product_id.ends_with(".lifetime1")
}

pub fn purchase_url(package: &str, product_id: &str, token: &str) -> String {
    if is_one_time(product_id) {
        format!(
            "{API_ORIGIN}/applications/{}/purchases/products/{}/tokens/{}",
            encode_segment(package),
            encode_segment(product_id),
            encode_segment(token)
        )
    } else {
        format!(
            "{API_ORIGIN}/applications/{}/purchases/subscriptionsv2/tokens/{}",
            encode_segment(package),
            encode_segment(token)
        )
    }
}

/// Percent-encodes everything outside the RFC 3986 unreserved set, so an opaque token cannot
/// change the path it is put in.
fn encode_segment(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            out.push(char::from(byte));
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// Whether a purchase, as Google reported it, buys the plan its product names right now.
///
/// `client_key` is the hex of the device's public key, and it must be passed only once the client's
/// proof has verified: an unproven client is not bound to anything. Every refusal is a rejection,
/// and the caller meters every rejection as free.
pub fn verdict(purchase: &PlayPurchase, product_id: &str, client_key: Option<&str>, now: u64) -> PlayVerdict {
    let Some(product) = PlayProduct::from_id(product_id) else {
        return PlayVerdict::Rejected(PlayRejection::UnknownProduct);
    };
    if purchase.product_id != product_id {
        return PlayVerdict::Rejected(PlayRejection::UnknownProduct);
    }
    if client_key.is_some_and(|key| !bound_to(purchase, key)) {
        return PlayVerdict::Rejected(PlayRejection::WrongDevice);
    }
    match live(purchase, now) {
        Ok(()) => PlayVerdict::Active(product.plan()),
        Err(reason) => PlayVerdict::Rejected(reason),
    }
}

fn live(purchase: &PlayPurchase, now: u64) -> Result<(), PlayRejection> {
    match purchase.state {
        PurchaseState::Expired | PurchaseState::OnHold | PurchaseState::Paused => Err(PlayRejection::Expired),
        PurchaseState::Pending => Err(PlayRejection::NotAPurchase),
        PurchaseState::Canceled if purchase.is_lifetime => Err(PlayRejection::NotAPurchase),
        PurchaseState::Active | PurchaseState::InGrace | PurchaseState::Canceled => {
            if purchase.is_lifetime {
                return Ok(());
            }
            match purchase.expiry_unix {
                Some(expiry) if expiry > now => Ok(()),
                Some(_) => Err(PlayRejection::Expired),
                None => Err(PlayRejection::Unavailable),
            }
        }
    }
}

fn bound_to(purchase: &PlayPurchase, client_key: &str) -> bool {
    let Some(key_bytes) = hex_bytes(client_key, MAX_CLIENT_KEY_HEX) else {
        return false;
    };
    purchase.obfuscated_account_id.as_deref() == Some(sha256_hex(&key_bytes).as_str())
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    digest(&SHA256, bytes).as_ref().iter().map(|byte| format!("{byte:02x}")).collect()
}

/// A `PlayApi` that answers with one fixed purchase, or refuses, and records what it was asked.
pub struct FakePlayApi {
    answer: Result<PlayPurchase, String>,
}

impl FakePlayApi {
    pub fn answering(purchase: PlayPurchase) -> Self {
        Self { answer: Ok(purchase) }
    }

    pub fn failing(message: &str) -> Self {
        Self { answer: Err(message.to_owned()) }
    }
}

impl PlayApi for FakePlayApi {
    fn purchase_state<'a>(
        &'a self,
        _package: &'a str,
        _product_id: &'a str,
        _token: &'a str,
    ) -> BoxFuture<'a, Result<PlayPurchase, BoxError>> {
        let answer = self.answer.clone().map_err(BoxError::from);
        Box::pin(async move { answer })
    }
}
