//! APNs (Apple Push Notification service) client.
//!
//! Sends alert notifications to iOS devices via Apple's HTTP/2 API. Used when a terminal on the
//! Mac needs the user's attention, including while Picture in Picture keeps a phone's control
//! channel connected after iOS has suspended the app itself.
//!
//! # Auth
//!
//! APNs uses ES256 JWTs: a JSON header and payload, base64url-encoded and signed with the
//! EC P-256 key from the `.p8` file Apple issues per team. The JWT carries the key ID (from the
//! portal) and the team ID, and is signed with ECDSA-P256-SHA256 in IEEE P1363 (fixed-size)
//! format. Apple allows the same token for up to an hour; this implementation caches it for 45
//! minutes so a deploy that never restarts still refreshes it well inside that window.
//!
//! # Wire
//!
//! One long-lived TLS+HTTP/2 connection per host (`api.push.apple.com:443`, ALPN `h2`) carries
//! every push; see `delivery` for the timeouts, limits and retry rules. Apple's server requires
//! HTTP/2. The `h2` crate handles the framing; `tokio-rustls` with `webpki-roots` handles TLS
//! certificate verification.

mod delivery;

use std::collections::HashMap;

use crate::activity::{ActivityEnvironment, ActivityFailure, ActivityRequest};
use crate::apns_policy::CircuitBreaker;
use crate::redact::tag;
use std::io::BufReader;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use bytes::Bytes;
use h2::client;
use http::{Method, Request, Uri};
use ring::rand::SystemRandom;
use ring::signature::{EcdsaKeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};
use tokio::sync::Semaphore;
use tracing::warn;

const APNS_HOST: &str = "api.push.apple.com";
/// The development host. The same key signs both — which environment a push goes to is decided by
/// the host it is sent to, and which one a token needs is decided by the entitlement the app that
/// registered it was signed with.
const APNS_SANDBOX_HOST: &str = "api.sandbox.push.apple.com";
const APNS_PORT: u16 = 443;
/// Refresh the JWT well before Apple's one-hour limit.
const MAX_REMEMBERED_ENVIRONMENTS: usize = 4096;
const JWT_TTL: Duration = Duration::from_secs(45 * 60);

struct CachedJwt {
    token: String,
    made_at: Instant,
}

pub struct ApnsClient {
    key_pair: EcdsaKeyPair,
    key_id: String,
    team_id: String,
    bundle_id: String,
    tls_config: Arc<tokio_rustls::rustls::ClientConfig>,
    cached_jwt: Mutex<Option<CachedJwt>>,
    /// Which host each device token was last accepted on, by token.
    ///
    /// **Because nothing in a token says which environment it belongs to.** A push to the wrong
    /// host is refused with `BadDeviceToken`, exactly as a push to a device that has uninstalled
    /// the app would be, so the only way to serve both a Debug phone and a TestFlight one from one
    /// relay is to try one, and then the other, and remember which answered.
    environments: Mutex<HashMap<String, &'static str>>,
    /// The open HTTP/2 connection to each host, shared by every push.
    connections: Mutex<HashMap<&'static str, client::SendRequest<Bytes>>>,
    in_flight: Semaphore,
    breaker: Mutex<CircuitBreaker>,
}

/// Where a tapped notification should take the phone: which Mac, and which of its sources.
#[derive(Clone, Copy, Debug)]
pub struct PushRoute<'a> {
    pub host_id: &'a str,
    pub source: Option<&'a str>,
    pub action: Option<PushAction<'a>>,
}

/// What an agent approval needs on the phone to be answered from the notification itself.
#[derive(Clone, Copy, Debug)]
pub struct PushAction<'a> {
    pub category: &'a str,
    pub session_id: &'a str,
    pub approval_id: &'a str,
    /// Answers for the phone's notification extension to turn into buttons; empty for the rest.
    pub options: &'a [String],
}

/// The APNs body. Compact JSON built by hand: the shape never varies.
///
/// The route rides beside `aps` as custom keys, `hostId` and `source`, which is where APNs puts
/// everything that is the app's rather than the system's.
fn payload(
    title: &str,
    body: &str,
    route: Option<PushRoute<'_>>,
) -> Result<String, serde_json::Error> {
    let action = route.and_then(|route| route.action);
    let mut category = match action {
        Some(action) => format!(r#","category":{}"#, serde_json::to_string(action.category)?),
        None => String::new(),
    };
    if action.is_some_and(|action| !action.options.is_empty()) {
        category.push_str(r#","mutable-content":1"#);
    }
    let mut payload = format!(
        r#"{{"aps":{{"alert":{{"title":{},"body":{}}},"sound":"default"{}}}"#,
        serde_json::to_string(title)?,
        serde_json::to_string(body)?,
        category,
    );
    if let Some(route) = route {
        payload.push_str(&format!(r#","hostId":{}"#, serde_json::to_string(route.host_id)?));
        if let Some(source) = route.source {
            payload.push_str(&format!(r#","source":{}"#, serde_json::to_string(source)?));
        }
        if let Some(action) = route.action {
            payload.push_str(&format!(
                r#","agentSessionId":{},"agentApprovalId":{}"#,
                serde_json::to_string(action.session_id)?,
                serde_json::to_string(action.approval_id)?,
            ));
            if !action.options.is_empty() {
                payload.push_str(&format!(r#","agentAnswers":{}"#, serde_json::to_string(action.options)?));
            }
        }
    }
    payload.push('}');
    Ok(payload)
}

impl ApnsClient {
    pub fn from_config(
        key_path: PathBuf,
        key_id: String,
        team_id: String,
        bundle_id: String,
    ) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let file = std::fs::File::open(&key_path)
            .map_err(|e| format!("could not open APNs key {}: {e}", key_path.display()))?;
        let key = rustls_pemfile::private_key(&mut BufReader::new(file))
            .map_err(|e| format!("could not read APNs key: {e}"))?
            .ok_or("no private key found in APNs .p8 file")?;
        // Apple always issues PKCS#8 EC keys for APNs.
        let key_der = match &key {
            rustls_pki_types::PrivateKeyDer::Pkcs8(k) => k.secret_pkcs8_der().to_vec(),
            _ => return Err("APNs key must be PKCS#8 (Apple's .p8 format)".into()),
        };

        let rng = SystemRandom::new();
        let key_pair = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &key_der, &rng)
            .map_err(|e| format!("invalid APNs key pair: {e}"))?;

        let mut root_store = tokio_rustls::rustls::RootCertStore::empty();
        root_store.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());

        // Explicit ring provider so the relay keeps building on musl without aws-lc-rs.
        let provider = Arc::new(tokio_rustls::rustls::crypto::ring::default_provider());
        let mut tls_config = tokio_rustls::rustls::ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .map_err(|e| format!("TLS protocol versions error: {e}"))?
            .with_root_certificates(root_store)
            .with_no_client_auth();
        // APNs only accepts HTTP/2; negotiate it in TLS so the handshake succeeds.
        tls_config.alpn_protocols = vec![b"h2".to_vec()];

        Ok(Self {
            key_pair,
            key_id,
            team_id,
            bundle_id,
            tls_config: Arc::new(tls_config),
            cached_jwt: Mutex::new(None),
            environments: Mutex::new(HashMap::new()),
            connections: Mutex::new(HashMap::new()),
            in_flight: Semaphore::new(delivery::MAX_PUSHES_IN_FLIGHT),
            breaker: Mutex::new(CircuitBreaker::default()),
        })
    }

    /// Returns a valid JWT, reusing the cached one when it is still fresh.
    fn jwt(&self) -> String {
        let mut guard = self.cached_jwt.lock().unwrap();
        if let Some(cached) = guard.as_ref() {
            if cached.made_at.elapsed() < JWT_TTL {
                return cached.token.clone();
            }
        }
        let token = self.mint_jwt();
        *guard = Some(CachedJwt {
            token: token.clone(),
            made_at: Instant::now(),
        });
        token
    }

    fn mint_jwt(&self) -> String {
        let header = format!(
            r#"{{"alg":"ES256","kid":"{}"}}"#,
            self.key_id
        );
        let iat = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let payload = format!(r#"{{"iss":"{}","iat":{}}}"#, self.team_id, iat);

        let header_b64 = URL_SAFE_NO_PAD.encode(header.as_bytes());
        let payload_b64 = URL_SAFE_NO_PAD.encode(payload.as_bytes());
        let signing_input = format!("{header_b64}.{payload_b64}");

        let rng = SystemRandom::new();
        let sig = self
            .key_pair
            .sign(&rng, signing_input.as_bytes())
            .expect("ECDSA signing is infallible for a valid key pair");
        let sig_b64 = URL_SAFE_NO_PAD.encode(sig.as_ref());

        format!("{signing_input}.{sig_b64}")
    }


    /// The host a token was last accepted on, or production.
    fn first_host(&self, device_token: &str) -> &'static str {
        self.environments.lock().unwrap().get(device_token).copied().unwrap_or(APNS_HOST)
    }

    fn remember_environment(&self, device_token: &str, host: &'static str) {
        let mut environments = self.environments.lock().unwrap();
        if environments.len() >= MAX_REMEMBERED_ENVIRONMENTS {
            environments.clear();
        }
        environments.insert(device_token.to_owned(), host);
    }

    fn forget_environment(&self, device_token: &str) {
        self.environments.lock().unwrap().remove(device_token);
    }

    /// Delivers one alert. The host that answered is remembered per token, and the other host is
    /// tried only for `BadDeviceToken`; see `deliver`.
    pub async fn send(
        &self,
        device_token: &str,
        title: &str,
        body: &str,
        route: Option<PushRoute<'_>>,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let request = ApnsRequest {
            push_type: "alert",
            topic: self.bundle_id.clone(),
            priority: 10,
            expiration: None,
            body: payload(title, body, route)?,
        };
        let first = self.first_host(device_token);
        self.deliver(first, device_token, &request, true).await.map_err(|error| {
            warn!(device_token = %tag(device_token), error = %error, "APNs did not take the push");
            error.to_string().into()
        })
    }

    /// Sends a Live Activity push. `environment` is the host to try first; without it, the token's
    /// remembered host, then production. Only a guessed host is retried on the other one, because
    /// a host the phone named is not a guess.
    pub async fn send_activity(
        &self,
        device_token: &str,
        environment: Option<ActivityEnvironment>,
        activity: &ActivityRequest,
    ) -> Result<(), ActivityFailure> {
        let first = match environment {
            Some(ActivityEnvironment::Production) => APNS_HOST,
            Some(ActivityEnvironment::Sandbox) => APNS_SANDBOX_HOST,
            None => self.first_host(device_token),
        };
        let request = ApnsRequest {
            push_type: "liveactivity",
            topic: format!("{}.push-type.liveactivity", self.bundle_id),
            priority: activity.priority,
            expiration: activity.expiration,
            body: activity.body.clone(),
        };
        self.deliver(first, device_token, &request, environment.is_none())
            .await
            .map_err(|error| {
                warn!(device_token = %tag(device_token), error = %error, "APNs did not take the live activity push");
                ActivityFailure::from(&error)
            })
    }
}

fn http_request(
    host: &str,
    device_token: &str,
    jwt: &str,
    request: &ApnsRequest,
) -> Result<Request<()>, Box<dyn std::error::Error + Send + Sync>> {
    let uri: Uri = format!("https://{host}/3/device/{device_token}").parse()?;
    let mut builder = Request::builder()
        .method(Method::POST)
        .uri(uri)
        .header("authorization", format!("bearer {jwt}"))
        .header("apns-topic", &request.topic)
        .header("apns-push-type", request.push_type)
        .header("apns-priority", request.priority.to_string())
        .header("content-type", "application/json")
        .header("content-length", request.body.len().to_string());
    if let Some(expiration) = request.expiration {
        builder = builder.header("apns-expiration", expiration.to_string());
    }
    Ok(builder.body(())?)
}

struct ApnsRequest {
    push_type: &'static str,
    topic: String,
    priority: u8,
    expiration: Option<u64>,
    body: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn live_activity(expiration: Option<u64>) -> ApnsRequest {
        ApnsRequest {
            push_type: "liveactivity",
            topic: "pl.example.app.push-type.liveactivity".into(),
            priority: 5,
            expiration,
            body: r#"{"aps":{}}"#.into(),
        }
    }

    #[test]
    fn a_live_activity_request_carries_its_push_type_topic_and_priority() {
        let request = http_request(APNS_SANDBOX_HOST, "abcd", "jwt", &live_activity(Some(1_800_000_090))).unwrap();
        let header = |name: &str| request.headers().get(name).and_then(|v| v.to_str().ok()).map(str::to_owned);
        assert_eq!(request.uri().to_string(), "https://api.sandbox.push.apple.com/3/device/abcd");
        assert_eq!(header("apns-push-type").as_deref(), Some("liveactivity"));
        assert_eq!(header("apns-topic").as_deref(), Some("pl.example.app.push-type.liveactivity"));
        assert_eq!(header("apns-priority").as_deref(), Some("5"));
        assert_eq!(header("apns-expiration").as_deref(), Some("1800000090"));
        assert_eq!(header("authorization").as_deref(), Some("bearer jwt"));
        assert_eq!(header("content-length").as_deref(), Some("10"));
    }

    #[test]
    fn a_request_without_an_expiration_sends_no_expiration_header() {
        let request = http_request(APNS_HOST, "abcd", "jwt", &live_activity(None)).unwrap();
        assert!(request.headers().get("apns-expiration").is_none());
    }

    fn parsed(text: &str) -> serde_json::Value {
        serde_json::from_str(text).expect("valid JSON")
    }

    #[test]
    fn payload_without_a_route_is_the_alert_alone() {
        let json = parsed(&payload("Title", "Body \"quoted\"", None).unwrap());
        assert_eq!(json["aps"]["alert"]["title"], "Title");
        assert_eq!(json["aps"]["alert"]["body"], "Body \"quoted\"");
        assert!(json.get("hostId").is_none());
        assert!(json.get("source").is_none());
    }

    #[test]
    fn payload_carries_the_route_beside_aps() {
        let route = PushRoute { host_id: "MAC-1", source: Some("window:42"), action: None };
        let json = parsed(&payload("T", "B", Some(route)).unwrap());
        assert_eq!(json["aps"]["sound"], "default");
        assert_eq!(json["hostId"], "MAC-1");
        assert_eq!(json["source"], "window:42");
    }

    #[test]
    fn payload_with_a_host_and_no_source_names_only_the_host() {
        let route = PushRoute { host_id: "MAC-1", source: None, action: None };
        let json = parsed(&payload("T", "B", Some(route)).unwrap());
        assert_eq!(json["hostId"], "MAC-1");
        assert!(json.get("source").is_none());
    }

    #[test]
    fn payload_carries_an_approval_category_and_its_ids() {
        let route = PushRoute {
            host_id: "MAC-1",
            source: None,
            action: Some(PushAction {
                category: "peering.agent.approval.tool",
                session_id: "S-1",
                approval_id: "A-1",
                options: &[],
            }),
        };
        let json = parsed(&payload("T", "B", Some(route)).unwrap());
        assert!(json["aps"].get("mutable-content").is_none());
        assert!(json.get("agentAnswers").is_none());
        assert_eq!(json["aps"]["category"], "peering.agent.approval.tool");
        assert_eq!(json["aps"]["sound"], "default");
        assert_eq!(json["agentSessionId"], "S-1");
        assert_eq!(json["agentApprovalId"], "A-1");
    }

    #[test]
    fn payload_with_options_asks_the_phone_to_build_their_buttons() {
        let options = ["Red".to_owned(), "Blue".to_owned()];
        let route = PushRoute {
            host_id: "MAC-1",
            source: None,
            action: Some(PushAction {
                category: "peering.agent.approval.open",
                session_id: "S-1",
                approval_id: "A-1",
                options: &options,
            }),
        };
        let json = parsed(&payload("T", "B", Some(route)).unwrap());
        assert_eq!(json["aps"]["mutable-content"], 1);
        assert_eq!(json["agentAnswers"], serde_json::json!(["Red", "Blue"]));
    }

    #[test]
    fn payload_without_an_action_has_no_category() {
        let route = PushRoute { host_id: "MAC-1", source: None, action: None };
        let json = parsed(&payload("T", "B", Some(route)).unwrap());
        assert!(json["aps"].get("category").is_none());
        assert!(json.get("agentApprovalId").is_none());
    }
}
