//! One HTTPS POST to a Google host, over HTTP/2 with TLS verified against the webpki roots.
//!
//! The same shape as `apns.rs`: a fresh TCP and TLS connection per request, ALPN `h2`, and the
//! ring provider so the relay builds without aws-lc-rs. Used by the FCM sender and by the OAuth
//! token exchange.

use std::sync::Arc;

use bytes::Bytes;
use h2::client;
use http::{Method, Request, Uri};
use rustls_pki_types::ServerName;
use tokio::net::TcpStream;
use tokio_rustls::TlsConnector;
use tokio_rustls::rustls::{ClientConfig, RootCertStore, crypto::ring::default_provider};

use crate::fcm_auth::BoxError;

const HTTPS_PORT: u16 = 443;
/// Google's replies here are small JSON documents. The cap keeps a hostile or broken peer from
/// making the relay buffer without limit.
const MAX_REPLY_BYTES: usize = 64 * 1024;

pub struct HttpsReply {
    pub status: u16,
    pub body: String,
}

pub fn tls_config() -> Result<Arc<ClientConfig>, BoxError> {
    let mut roots = RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let provider = Arc::new(default_provider());
    let mut config = ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|error| format!("TLS protocol versions error: {error}"))?
        .with_root_certificates(roots)
        .with_no_client_auth();
    config.alpn_protocols = vec![b"h2".to_vec()];
    Ok(Arc::new(config))
}

/// Sends one request to `url` with the given headers and returns the status and the reply body.
pub async fn request(
    tls: &Arc<ClientConfig>,
    method: Method,
    url: &str,
    headers: &[(&str, &str)],
    body: Bytes,
) -> Result<HttpsReply, BoxError> {
    let uri: Uri = url.parse()?;
    let host = uri.host().ok_or("request URL has no host")?.to_owned();

    let tcp = TcpStream::connect((host.as_str(), HTTPS_PORT)).await?;
    let server_name = ServerName::try_from(host)?;
    let tls_stream = TlsConnector::from(Arc::clone(tls)).connect(server_name, tcp).await?;

    let (h2, connection) = client::Builder::new().handshake::<_, Bytes>(tls_stream).await?;
    tokio::spawn(async move {
        let _ = connection.await;
    });

    let mut builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("content-length", body.len().to_string());
    for (name, value) in headers {
        builder = builder.header(*name, *value);
    }
    let request = builder.body(())?;

    let mut ready = h2.ready().await?;
    let (response, mut send_stream) = ready.send_request(request, false)?;
    send_stream.send_data(body, true)?;

    let response = response.await?;
    let status = response.status().as_u16();
    let mut stream = response.into_body();
    let mut received = Vec::new();
    while let Some(chunk) = stream.data().await {
        let chunk = chunk?;
        stream.flow_control().release_capacity(chunk.len())?;
        if received.len() + chunk.len() > MAX_REPLY_BYTES {
            return Err("Google's reply is larger than the relay will read".into());
        }
        received.extend_from_slice(&chunk);
    }
    Ok(HttpsReply {
        status,
        body: String::from_utf8_lossy(&received).into_owned(),
    })
}
