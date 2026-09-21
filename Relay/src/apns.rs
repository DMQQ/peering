//! APNs (Apple Push Notification service) client.
//!
//! Sends alert notifications to iOS devices via Apple's HTTP/2 API. Used when a terminal on the
//! Mac needs the user's attention and the phone is no longer connected over the control channel.
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
    pub async fn send(
        &self,
        device_token: &str,
        title: &str,
        body: &str,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let jwt = self.jwt();

        // Compact JSON — serde_json would pull in more deps; the shape never varies.
        let payload = format!(
            r#"{{"aps":{{"alert":{{"title":{title_json},"body":{body_json}}},"sound":"default"}}}}"#,
            title_json = serde_json::to_string(title)?,
            body_json = serde_json::to_string(body)?,
        );
        let payload_bytes = Bytes::from(payload.into_bytes());
        let content_length = payload_bytes.len().to_string();

        let tcp = TcpStream::connect((APNS_HOST, APNS_PORT)).await?;
        let connector = TlsConnector::from(Arc::clone(&self.tls_config));
        let server_name = ServerName::try_from(APNS_HOST)
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

        let uri: Uri = format!("https://{APNS_HOST}/3/device/{device_token}").parse()?;
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
        if !status.is_success() {
            warn!(
                %status,
                %device_token,
                "APNs push rejected"
            );
        }

        Ok(())
    }
}
