//! Google OAuth access tokens for Firebase Cloud Messaging, minted from a service account key.
//!
//! The relay signs a JWT assertion with the service account's RSA key (RS256), exchanges it at the
//! account's `token_uri` for an access token, and reuses that token until shortly before it lapses.
//! The exchange is behind `TokenExchange` so that nothing above it touches the network in tests.

use std::future::Future;
use std::io::BufReader;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use ring::rand::SystemRandom;
use ring::signature::{RSA_PKCS1_SHA256, RsaKeyPair};
use rustls_pki_types::PrivateKeyDer;
use serde::Deserialize;
use serde_json::json;

pub const FCM_SCOPE: &str = "https://www.googleapis.com/auth/firebase.messaging";
const ASSERTION_LIFETIME_SECONDS: u64 = 3600;
const TOKEN_TTL_SECONDS: u64 = 45 * 60;

type BoxError = Box<dyn std::error::Error + Send + Sync>;

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

    pub fn project_id(&self) -> &str {
        &self.project_id
    }

    pub fn token_uri(&self) -> &str {
        &self.token_uri
    }

    /// The signed JWT that asks Google for an access token, valid for an hour from `now`.
    pub fn build_assertion(&self, now: u64) -> Result<String, BoxError> {
        let header = URL_SAFE_NO_PAD.encode(br#"{"alg":"RS256","typ":"JWT"}"#);
        let claims = json!({
            "iss": self.client_email,
            "scope": FCM_SCOPE,
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

struct HeldToken {
    token: String,
    valid_until: u64,
}

/// Holds one access token and renews it through the exchange once it is 45 minutes old, or sooner
/// if Google said it would lapse earlier.
pub struct AccessTokenCache<C, E> {
    account: ServiceAccount,
    exchange: E,
    clock: C,
    held: Mutex<Option<HeldToken>>,
}

impl<C: Clock, E: TokenExchange> AccessTokenCache<C, E> {
    pub fn new(account: ServiceAccount, exchange: E, clock: C) -> Self {
        Self { account, exchange, clock, held: Mutex::new(None) }
    }

    pub fn account(&self) -> &ServiceAccount {
        &self.account
    }

    pub async fn access_token(&self) -> Result<String, BoxError> {
        let now = self.clock.unix_seconds();
        if let Some(token) = self.fresh_token(now) {
            return Ok(token);
        }
        let assertion = self.account.build_assertion(now)?;
        let reply = self.exchange.exchange(&assertion).await?;
        let valid_until = now + TOKEN_TTL_SECONDS.min(reply.expires_in);
        *self.held.lock().unwrap() = Some(HeldToken {
            token: reply.access_token.clone(),
            valid_until,
        });
        Ok(reply.access_token)
    }

    fn fresh_token(&self, now: u64) -> Option<String> {
        let held = self.held.lock().unwrap();
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
        async move { reply }
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
mod tests {
    use super::*;
    use ring::signature::{RSA_PKCS1_2048_8192_SHA256, UnparsedPublicKey};

    /// A throwaway 2048 bit key generated for these tests. It signs nothing outside them and is
    /// not a secret.
    const TEST_ONLY_KEY: &str = "-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDfFfZXtO5r2Eq3
5cwWJXCJXZjHocErwbLErm40mmznyiDCSlEyNpAbQCaYctXkxBrgSttmH29TXDTN
ZsL5iurN9uq7sBsJEPpsFrLY4eCZzqVntC2Br0t+iEZwaZEH3XIN2dxog73qKc7R
5gkrQYLiH+iDbo6kvsSJRRLPjc7BVrtF+6CkMdhslhpmktBBnA6klqtwsxBD3XJ4
O8juFLhTphkB4ByN6SO+MDaQ0PC0LUxQ9BQrunoNeOTy+1/J5B94BCR//ikLi2wV
C0H045Di0jdEAodyb9iiLrs0MOhVEKrk803iNDcjfo110h5xGPLyBGEoN6oMR0ms
0mBUWbDdAgMBAAECggEBAK4Lemeu9xwYYSLcG79jcksZRKrrHcQ/mHMuCzjrCfBE
mA484OAmBYPdJr9lSE70WGuIu2cPO1Fz7JYbiB4cLViHPVc068LFBjrx8pKWlx4o
RI+F2MMGugV72Ei3c7kJIYSA5h58OdzIxVyo9ZpTwAMfFc4EoTESzE60Hxri7d2T
kh9eRGCtMQ9J0ZQGXkWgj8Pm3PzdXCG8rRhp0aqi1soCuXaausGdN9fqLpvOVSxo
3Zo6EupTwOHnXNIdqX0CpdSsiYa1JWbnYuQl53GRV/k+Q3Cer6hsxoDJzq+brtA5
gnFt1LPsvC8j1UiKKLRjEVQZpRPxAhXx9b+N8BzAiNkCgYEA77dKUHY8MAj/At77
Fw/CBehjeCeLZOdiFBejF1u6J6bfTB0bEToLbXJ8XWIduMt3DvWHsHH36meIn3++
KkJzT8pl5VGi20UYgwGPH4850/CV1AS7lt5mUKbrJuXAN2xykEPlA17PdvS8JGYD
RNrl8NJo524ESMJb5YJlvKyXs9sCgYEA7j14Ofblfzr4Y/63ProxpZ4JHkxlzKGa
NOe6BNAvjyiZKRzyDxnd7NMY9shvgDv0mtl3o6QY19GOlYhBYwSUwZUSn/opdIIF
eMuApH9k77FTch+DV0h7VQYltgujE+yr6NirpUIv7Y4o5f2drS7rT8s3krGMZs/A
kwMfSQIHJ6cCgYA3Wi6Jx9N8EAe6hPybxaK6tH+Ldi4k3ZzzIMYjFaY1k73KGIpw
fuO2oRIAijBsxGa4iI+NebOSZ9fPZLLnlTKFQSooOqKNWTYgwhJnai4jN1GRhIpA
exhLFVAFSlYJNjx5/YN7NMBZKofrK7cjhhxEcIGStv+8QUzxARw25e+dswKBgBPn
GLsm8Cc/4u5foilgXrNqT3KziTGeMobG8Rhj2AVKq/juTR6L16loPUaomgAJgjbJ
giAunlCxVgsR9fxyroa5kHPC72GnVxOvVJDpf6IymzkGfu90w7DnsZDSyg3pELeE
GlrU+7IJ1UrZdCm6qLfiz0K3CHayVnExqpRr0fMzAoGAWQpRBcXojYdw2/3e8znb
Tab2krz9HPNCbFPcEwDE9Te57ejEBkKYNdhMzKnvQ5SOPiZDhjNHTAsBy/SRvcYS
UV9LON0HHY3L/dIVOfg0YVrM+/RsUNatdUwbdZTgvhZdTkiudLne25l1F3xpLyXZ
gVM0SkdAdMeNmluvfJbJz6A=
-----END PRIVATE KEY-----
";

    fn key_file(private_key: &str) -> String {
        json!({
            "type": "service_account",
            "project_id": "peering-test",
            "client_email": "relay@peering-test.iam.gserviceaccount.com",
            "private_key": private_key,
            "token_uri": "https://oauth2.googleapis.com/token",
        })
        .to_string()
    }

    fn account() -> ServiceAccount {
        ServiceAccount::from_json(&key_file(TEST_ONLY_KEY)).expect("the test key parses")
    }

    fn decode_segment(segment: &str) -> serde_json::Value {
        let bytes = URL_SAFE_NO_PAD.decode(segment).expect("base64url");
        serde_json::from_slice(&bytes).expect("JSON")
    }

    #[test]
    fn the_service_account_file_yields_its_project_and_token_endpoint() {
        let account = account();
        assert_eq!(account.project_id(), "peering-test");
        assert_eq!(account.token_uri(), "https://oauth2.googleapis.com/token");
    }

    #[test]
    fn a_file_without_a_key_is_refused() {
        assert!(ServiceAccount::from_json(&key_file("not a key")).is_err());
        assert!(ServiceAccount::from_json("{}").is_err());
    }

    #[test]
    fn the_assertion_has_three_parts() {
        let assertion = account().build_assertion(1_000).expect("signs");
        assert_eq!(assertion.split('.').count(), 3);
    }

    #[test]
    fn the_header_and_claims_are_the_ones_google_expects() {
        let assertion = account().build_assertion(1_000).expect("signs");
        let parts: Vec<&str> = assertion.split('.').collect();
        assert_eq!(decode_segment(parts[0]), json!({"alg": "RS256", "typ": "JWT"}));
        assert_eq!(
            decode_segment(parts[1]),
            json!({
                "iss": "relay@peering-test.iam.gserviceaccount.com",
                "scope": FCM_SCOPE,
                "aud": "https://oauth2.googleapis.com/token",
                "iat": 1_000,
                "exp": 4_600,
            })
        );
    }

    #[test]
    fn the_signature_verifies_with_the_public_half_of_the_key() {
        let account = account();
        let assertion = account.build_assertion(1_000).expect("signs");
        let (signed, signature) = assertion.rsplit_once('.').expect("three parts");
        let signature = URL_SAFE_NO_PAD.decode(signature).expect("base64url");
        let public = UnparsedPublicKey::new(
            &RSA_PKCS1_2048_8192_SHA256,
            account.key_pair.public().as_ref(),
        );
        assert!(public.verify(signed.as_bytes(), &signature).is_ok());
        assert!(public.verify(b"tampered", &signature).is_err());
    }

    #[tokio::test]
    async fn a_token_is_reused_until_45_minutes_have_passed() {
        let exchange = FakeTokenExchange::replying("ya29.first", 3600);
        let cache = AccessTokenCache::new(account(), exchange, FixedClock::at(1_000));
        assert_eq!(cache.access_token().await.unwrap(), "ya29.first");
        cache.clock.advance(2_699);
        assert_eq!(cache.access_token().await.unwrap(), "ya29.first");
        assert_eq!(cache.exchange.calls(), 1);
    }

    #[tokio::test]
    async fn a_token_is_renewed_once_45_minutes_have_passed() {
        let exchange = FakeTokenExchange::replying("ya29.renewed", 3600);
        let cache = AccessTokenCache::new(account(), exchange, FixedClock::at(1_000));
        cache.access_token().await.unwrap();
        cache.clock.advance(2_700);
        cache.access_token().await.unwrap();
        assert_eq!(cache.exchange.calls(), 2);
        let assertion = cache.exchange.last_assertion().expect("an assertion was sent");
        let claims = assertion.split('.').nth(1).expect("claims");
        assert_eq!(decode_segment(claims)["iat"], 3_700);
    }

    #[tokio::test]
    async fn a_shorter_lifetime_from_google_is_respected() {
        let exchange = FakeTokenExchange::replying("ya29.short", 600);
        let cache = AccessTokenCache::new(account(), exchange, FixedClock::at(1_000));
        cache.access_token().await.unwrap();
        cache.clock.advance(600);
        cache.access_token().await.unwrap();
        assert_eq!(cache.exchange.calls(), 2);
    }

    #[tokio::test]
    async fn a_failed_exchange_is_reported_and_not_remembered() {
        let exchange = FakeTokenExchange::failing("invalid_grant");
        let cache = AccessTokenCache::new(account(), exchange, FixedClock::at(1_000));
        assert!(cache.access_token().await.is_err());
        assert!(cache.access_token().await.is_err());
        assert_eq!(cache.exchange.calls(), 2);
    }
}
