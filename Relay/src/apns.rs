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
//! Each push is a new TLS+HTTP/2 connection to `api.push.apple.com:443` with ALPN `h2`. Apple's
//! server requires HTTP/2; they deprecated HTTP/1.1 support years ago. The `h2` crate handles
//! the framing; `tokio-rustls` with `webpki-roots` handles TLS certificate verification.

use std::collections::HashMap;
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
use rustls_pki_types::ServerName;
use tokio::net::TcpStream;
use tokio_rustls::TlsConnector;
use tracing::warn;

const APNS_HOST: &str = "api.push.apple.com";
/// The development host. The same key signs both — which environment a push goes to is decided by
/// the host it is sent to, and which one a token needs is decided by the entitlement the app that
/// registered it was signed with.
const APNS_SANDBOX_HOST: &str = "api.sandbox.push.apple.com";
const APNS_PORT: u16 = 443;
/// Refresh the JWT well before Apple's one-hour limit.
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
}

/// Where a tapped notification should take the phone: which Mac, and which of its sources.
#[derive(Clone, Copy, Debug)]
pub struct PushRoute<'a> {
    pub host_id: &'a str,
    pub source: Option<&'a str>,
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
    let mut payload = format!(
        r#"{{"aps":{{"alert":{{"title":{},"body":{}}},"sound":"default"}}"#,
        serde_json::to_string(title)?,
        serde_json::to_string(body)?,
    );
    if let Some(route) = route {
        payload.push_str(&format!(r#","hostId":{}"#, serde_json::to_string(route.host_id)?));
        if let Some(source) = route.source {
            payload.push_str(&format!(r#","source":{}"#, serde_json::to_string(source)?));
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

    /// Opens a connection to APNs and delivers one push notification. Each call is one
    /// connection; APNs is stateless from this relay's perspective.
    ///
    /// **Two attempts at most, and the second only for the reason that needs it.** Which
    /// environment a token belongs to is decided by the entitlement of the app that registered it,
    /// and the token carries nothing that says so: a phone running a build signed `development`
    /// — every Debug install — holds a token the production host refuses with `BadDeviceToken`,
    /// and that refusal is indistinguishable from a token for an app that has been uninstalled.
    /// So the host that answered is remembered per token, and a `BadDeviceToken` is the one
    /// answer worth trying the other host for.
    pub async fn send(
        &self,
        device_token: &str,
        title: &str,
        body: &str,
        route: Option<PushRoute<'_>>,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let first = self
            .environments
            .lock()
            .unwrap()
            .get(device_token)
            .copied()
            .unwrap_or(APNS_HOST);

        match self.push(first, device_token, title, body, route).await {
            PushOutcome::Accepted => Ok(()),
            PushOutcome::Refused(failure) => {
                let other = if first == APNS_HOST { APNS_SANDBOX_HOST } else { APNS_HOST };
                warn!(%device_token, host = first, failure = %failure, "APNs refused the push");

                match self.push(other, device_token, title, body, route).await {
                    PushOutcome::Accepted => {
                        self.environments
                            .lock()
                            .unwrap()
                            .insert(device_token.to_owned(), other);
                        Ok(())
                    }
                    PushOutcome::Refused(other_failure) => {
                        warn!(%device_token, host = other, failure = %other_failure, "APNs refused the push on both hosts");
                        Err(format!("APNs refused on both hosts: {failure} / {other_failure}").into())
                    }
                    PushOutcome::Failed(error) => Err(error),
                }
            }
            PushOutcome::Failed(error) => Err(error),
        }
    }

        /// One attempt against one host.
    async fn push(
        &self,
        host: &'static str,
        device_token: &str,
        title: &str,
        body: &str,
        route: Option<PushRoute<'_>>,
    ) -> PushOutcome {
        match self.push_inner(host, device_token, title, body, route).await {
            Ok(outcome) => outcome,
            Err(error) => PushOutcome::Failed(error),
        }
    }

    async fn push_inner(
        &self,
        host: &str,
        device_token: &str,
        title: &str,
        body: &str,
        route: Option<PushRoute<'_>>,
    ) -> Result<PushOutcome, Box<dyn std::error::Error + Send + Sync>> {
        let jwt = self.jwt();
        let payload = payload(title, body, route)?;
        let payload_bytes = Bytes::from(payload.into_bytes());
        let content_length = payload_bytes.len().to_string();

        let tcp = TcpStream::connect((host, APNS_PORT)).await?;
        let connector = TlsConnector::from(Arc::clone(&self.tls_config));
        let server_name = ServerName::try_from(host)
            .map_err(|_| "invalid APNs hostname")?
            .to_owned();
        let tls = connector.connect(server_name, tcp).await?;

        let (h2_client, conn) = client::Builder::new()
            .handshake::<_, Bytes>(tls)
            .await?;
        // Drive the connection in the background; it drops when the request finishes.
        tokio::spawn(async move {
            let _ = conn.await;
        });

        let uri: Uri = format!("https://{host}/3/device/{device_token}").parse()?;
        let req = Request::builder()
            .method(Method::POST)
            .uri(uri)
            .header("authorization", format!("bearer {jwt}"))
            .header("apns-topic", &self.bundle_id)
            .header("apns-push-type", "alert")
            .header("apns-priority", "10")
            .header("content-type", "application/json")
            .header("content-length", content_length)
            .body(())?;

        let mut h2_ready = h2_client.ready().await?;
        let (response_fut, mut send_stream) = h2_ready.send_request(req, false)?;
        send_stream.send_data(payload_bytes, true)?;

        let response = response_fut.await?;
        let status = response.status();
        if status.is_success() {
            return Ok(PushOutcome::Accepted);
        }

        // The body carries Apple's own word for it. Read rather than assumed, because
        // `BadDeviceToken` is the one refusal that means "try the other host" and everything else
        // means this push is not going to arrive.
        let body = response.into_body().data().await;
        let reason = match body {
            Some(Ok(bytes)) => String::from_utf8_lossy(&bytes).to_string(),
            _ => String::new(),
        };
        if reason.contains("BadDeviceToken") {
            return Ok(PushOutcome::Refused(reason));
        }
        Ok(PushOutcome::Refused(format!("{status} {reason}")))
    }
}

/// What one attempt against one host produced.
enum PushOutcome {
    /// APNs took it.
    Accepted,
    /// APNs answered, and not with success. The string is what it said.
    Refused(String),
    /// The attempt never reached Apple: DNS, TLS, HTTP/2, a socket.
    Failed(Box<dyn std::error::Error + Send + Sync>),
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let route = PushRoute { host_id: "MAC-1", source: Some("window:42") };
        let json = parsed(&payload("T", "B", Some(route)).unwrap());
        assert_eq!(json["aps"]["sound"], "default");
        assert_eq!(json["hostId"], "MAC-1");
        assert_eq!(json["source"], "window:42");
    }

    #[test]
    fn payload_with_a_host_and_no_source_names_only_the_host() {
        let route = PushRoute { host_id: "MAC-1", source: None };
        let json = parsed(&payload("T", "B", Some(route)).unwrap());
        assert_eq!(json["hostId"], "MAC-1");
        assert!(json.get("source").is_none());
    }
}
