//! Google OAuth access tokens for Firebase Cloud Messaging, minted from a service account key.
//!
//! The relay signs a JWT assertion with the service account's RSA key (RS256), exchanges it at the
//! account's `token_uri` for an access token, and reuses that token until shortly before it lapses.
//! The exchange is behind `TokenExchange` so that nothing above it touches the network in tests.

use std::future::Future;
use std::io::BufReader;
use std::path::Path;
use std::sync::{Arc, Mutex, PoisonError};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use ring::rand::SystemRandom;
use ring::signature::{RSA_PKCS1_SHA256, RsaKeyPair};
use rustls_pki_types::PrivateKeyDer;
use serde::Deserialize;
use serde_json::json;
use tokio_rustls::rustls::ClientConfig;
use bytes::Bytes;
use http::Method;

use crate::fcm::https;

pub const FCM_SCOPE: &str = "https://www.googleapis.com/auth/firebase.messaging";
const ASSERTION_LIFETIME_SECONDS: u64 = 3600;
const TOKEN_TTL_SECONDS: u64 = 45 * 60;

pub type BoxError = Box<dyn std::error::Error + Send + Sync>;

#[derive(Deserialize)]
struct KeyFile {
    client_email: String,
    private_key: String,
    token_uri: String,
    project_id: String,
}

/// The parts of a Google service account file the relay uses, with its signing key parsed.
pub struct ServiceAccount {
    client_email: String,
    token_uri: String,
    project_id: String,
    key_pair: RsaKeyPair,
}

impl ServiceAccount {
    pub fn from_json(text: &str) -> Result<Self, BoxError> {
        let file: KeyFile = serde_json::from_str(text)
            .map_err(|error| format!("service account file is not the expected JSON: {error}"))?;
        let key_pair = RsaKeyPair::from_pkcs8(&pkcs8_der(&file.private_key)?)
            .map_err(|_| "service account private key is not a usable RSA key")?;
        Ok(Self {
            client_email: file.client_email,
            token_uri: file.token_uri,
            project_id: file.project_id,
            key_pair,
        })
    }

    pub fn from_file(path: &Path) -> Result<Self, BoxError> {
        let text = std::fs::read_to_string(path)
            .map_err(|error| format!("could not read the service account file {}: {error}", path.display()))?;
        Self::from_json(&text)
    }

    pub fn project_id(&self) -> &str {
        &self.project_id
    }

    pub fn token_uri(&self) -> &str {
        &self.token_uri
    }

    /// The signed JWT that asks Google for an access token with `scope`, valid for an hour from `now`.
    pub fn build_assertion(&self, scope: &str, now: u64) -> Result<String, BoxError> {
        let header = URL_SAFE_NO_PAD.encode(br#"{"alg":"RS256","typ":"JWT"}"#);
        let claims = json!({
            "iss": self.client_email,
            "scope": scope,
            "aud": self.token_uri,
            "iat": now,
            "exp": now + ASSERTION_LIFETIME_SECONDS,
        });
        let signing_input = format!("{header}.{}", URL_SAFE_NO_PAD.encode(claims.to_string()));
        let mut signature = vec![0; self.key_pair.public().modulus_len()];
        self.key_pair
            .sign(&RSA_PKCS1_SHA256, &SystemRandom::new(), signing_input.as_bytes(), &mut signature)
            .map_err(|_| "could not sign the FCM assertion")?;
        Ok(format!("{signing_input}.{}", URL_SAFE_NO_PAD.encode(signature)))
    }
}

fn pkcs8_der(pem: &str) -> Result<Vec<u8>, BoxError> {
    match rustls_pemfile::private_key(&mut BufReader::new(pem.as_bytes()))? {
        Some(PrivateKeyDer::Pkcs8(key)) => Ok(key.secret_pkcs8_der().to_vec()),
        Some(_) => Err("service account private key must be PKCS#8".into()),
        None => Err("service account file has no private key".into()),
    }
}

/// Seconds since the Unix epoch. Injected so that expiry can be tested without waiting.
pub trait Clock: Send + Sync {
    fn unix_seconds(&self) -> u64;
}

pub struct SystemClock;

impl Clock for SystemClock {
    fn unix_seconds(&self) -> u64 {
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs()
    }
}

/// An access token and how long Google says it lasts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TokenReply {
    pub access_token: String,
    pub expires_in: u64,
}

/// Trades a signed assertion for an access token. The HTTP implementation lives beside the FCM
/// transport; tests use `FakeTokenExchange`.
pub trait TokenExchange: Send + Sync {
    fn exchange(&self, assertion: &str) -> impl Future<Output = Result<TokenReply, BoxError>> + Send;
}

const JWT_BEARER_GRANT: &str = "urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer";

#[derive(Deserialize)]
struct TokenBody {
    access_token: String,
    expires_in: u64,
}

#[derive(Deserialize)]
struct TokenErrorBody {
    error: String,
}

/// Reads Google's answer to a token request. Only the reason a refusal names is kept, never the body.
pub fn parse_token_reply(status: u16, body: &str) -> Result<TokenReply, BoxError> {
    if status != 200 {
        let reason = serde_json::from_str::<TokenErrorBody>(body)
            .map(|parsed| parsed.error)
            .unwrap_or_else(|_| format!("status {status}"));
        return Err(format!("Google refused the access token request: {reason}").into());
    }
    let parsed: TokenBody = serde_json::from_str(body)
        .map_err(|error| format!("Google's token reply is not the expected JSON: {error}"))?;
    Ok(TokenReply { access_token: parsed.access_token, expires_in: parsed.expires_in })
}

/// The OAuth exchange over HTTPS, posting the assertion to the account's `token_uri`.
pub struct HttpTokenExchange {
    token_uri: String,
    tls: Arc<ClientConfig>,
}

impl HttpTokenExchange {
    pub fn new(token_uri: String, tls: Arc<ClientConfig>) -> Self {
        Self { token_uri, tls }
    }
}

impl TokenExchange for HttpTokenExchange {
    async fn exchange(&self, assertion: &str) -> Result<TokenReply, BoxError> {
        let form = format!("grant_type={JWT_BEARER_GRANT}&assertion={assertion}");
        let reply = https::request(
            &self.tls,
            Method::POST,
            &self.token_uri,
            &[("content-type", "application/x-www-form-urlencoded")],
            Bytes::from(form),
        )
        .await?;
        parse_token_reply(reply.status, &reply.body)
    }
}

struct HeldToken {
    token: String,
    valid_until: u64,
}

/// Holds one access token and renews it through the exchange once it is 45 minutes old, or sooner
/// if Google said it would lapse earlier.
pub struct AccessTokenCache<C, E> {
    account: ServiceAccount,
    scope: &'static str,
    exchange: E,
    clock: C,
    held: Mutex<Option<HeldToken>>,
    /// Held across the exchange so that a burst of pushes with an expired token makes one request
    /// to Google rather than one each.
    renewing: tokio::sync::Mutex<()>,
}

impl<C: Clock, E: TokenExchange> AccessTokenCache<C, E> {
    pub fn new(account: ServiceAccount, scope: &'static str, exchange: E, clock: C) -> Self {
        Self { account, scope, exchange, clock, held: Mutex::new(None), renewing: tokio::sync::Mutex::new(()) }
    }

    pub fn account(&self) -> &ServiceAccount {
        &self.account
    }

    pub async fn access_token(&self) -> Result<String, BoxError> {
        let now = self.clock.unix_seconds();
        if let Some(token) = self.fresh_token(now) {
            return Ok(token);
        }
        let _renewing = self.renewing.lock().await;
        let now = self.clock.unix_seconds();
        if let Some(token) = self.fresh_token(now) {
            return Ok(token);
        }
        let assertion = self.account.build_assertion(self.scope, now)?;
        let reply = self.exchange.exchange(&assertion).await?;
        let valid_until = now + TOKEN_TTL_SECONDS.min(reply.expires_in);
        *self.held.lock().unwrap_or_else(PoisonError::into_inner) = Some(HeldToken {
            token: reply.access_token.clone(),
            valid_until,
        });
        Ok(reply.access_token)
    }

    fn fresh_token(&self, now: u64) -> Option<String> {
        let held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
        held.as_ref()
            .filter(|held| now < held.valid_until)
            .map(|held| held.token.clone())
    }
}

/// An exchange that answers from a fixed reply and counts the assertions it was given.
pub struct FakeTokenExchange {
    reply: Result<TokenReply, String>,
    calls: AtomicU64,
    last_assertion: Mutex<Option<String>>,
}

impl FakeTokenExchange {
    pub fn replying(access_token: &str, expires_in: u64) -> Self {
        Self {
            reply: Ok(TokenReply { access_token: access_token.to_owned(), expires_in }),
            calls: AtomicU64::new(0),
            last_assertion: Mutex::new(None),
        }
    }

    pub fn failing(message: &str) -> Self {
        Self {
            reply: Err(message.to_owned()),
            calls: AtomicU64::new(0),
            last_assertion: Mutex::new(None),
        }
    }

    pub fn calls(&self) -> u64 {
        self.calls.load(Ordering::SeqCst)
    }

    pub fn last_assertion(&self) -> Option<String> {
        self.last_assertion.lock().unwrap().clone()
    }
}

impl TokenExchange for FakeTokenExchange {
    fn exchange(&self, assertion: &str) -> impl Future<Output = Result<TokenReply, BoxError>> + Send {
        self.calls.fetch_add(1, Ordering::SeqCst);
        *self.last_assertion.lock().unwrap() = Some(assertion.to_owned());
        let reply = self.reply.clone().map_err(BoxError::from);
        async move {
            tokio::task::yield_now().await;
            reply
        }
    }
}

/// A clock the test moves by hand.
pub struct FixedClock {
    now: AtomicU64,
}

impl FixedClock {
    pub fn at(now: u64) -> Self {
        Self { now: AtomicU64::new(now) }
    }

    pub fn advance(&self, seconds: u64) {
        self.now.fetch_add(seconds, Ordering::SeqCst);
    }
}

impl Clock for FixedClock {
    fn unix_seconds(&self) -> u64 {
        self.now.load(Ordering::SeqCst)
    }
}

#[cfg(test)]
mod tests;
