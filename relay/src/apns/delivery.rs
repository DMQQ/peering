//! Getting one push to Apple and reading what came back.
//!
//! One HTTP/2 connection per APNs host is kept open and shared by every push, as Apple asks: a
//! connection per push costs a TLS handshake each and looks like a connection flood to Apple. A
//! dead connection is found when the next push asks it for a stream, and replaced once.
//!
//! Every push is bounded three ways: by a total timeout, by a count of pushes in flight, and by a
//! circuit breaker that stops sending while Apple answers 429 or 5xx.

use std::fmt;
use std::sync::Arc;
use std::time::{Duration, Instant};

use bytes::Bytes;
use h2::client;
use rustls_pki_types::ServerName;
use tokio::net::TcpStream;
use tokio::time::timeout;
use tokio_rustls::TlsConnector;
use tracing::warn;

use super::{ApnsClient, ApnsRequest, APNS_HOST, APNS_PORT, APNS_SANDBOX_HOST, http_request};
use crate::activity::ActivityFailure;
use crate::apns_policy::{ApnsRefusal, may_refresh_jwt};
use crate::redact::tag;

type BoxError = Box<dyn std::error::Error + Send + Sync>;

/// Covers connecting, the request, Apple's answer, and a retry on the other host.
pub(super) const PUSH_TIMEOUT: Duration = Duration::from_secs(10);
pub(super) const MAX_PUSHES_IN_FLIGHT: usize = 64;
/// Apple's error bodies are a line of JSON.
const MAX_REPLY_BYTES: usize = 4096;

/// Why a push did not arrive.
#[derive(Debug)]
pub(crate) enum DeliverError {
    /// Apple answered, and not with success.
    Refused(ApnsRefusal),
    /// Apple asked this relay to slow down, the breaker is open, or too many pushes are in flight.
    Throttled,
    /// The push never got an answer: DNS, TLS, HTTP/2, a socket, or the timeout.
    Unreachable(String),
}

impl fmt::Display for DeliverError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Refused(refusal) => write!(f, "APNs refused the push: {refusal}"),
            Self::Throttled => write!(f, "APNs is being given a rest after throttling or errors"),
            Self::Unreachable(reason) => write!(f, "APNs was not reached: {reason}"),
        }
    }
}

impl From<&DeliverError> for ActivityFailure {
    fn from(error: &DeliverError) -> Self {
        match error {
            DeliverError::Refused(refusal) => Self::from_refusal(refusal),
            DeliverError::Throttled => Self::Throttled,
            DeliverError::Unreachable(_) => Self::Unavailable,
        }
    }
}

enum Attempt {
    Accepted,
    Refused(ApnsRefusal),
}

impl ApnsClient {
    /// Sends `request` to `first`, and to the other host only when `may_switch` and Apple says
    /// `BadDeviceToken`, which is how a token from the other environment is refused. Every other
    /// refusal means this push is not going to arrive on either host, and Apple asks that it not
    /// be retried.
    pub(super) async fn deliver(
        &self,
        first: &'static str,
        device_token: &str,
        request: &ApnsRequest,
        may_switch: bool,
    ) -> Result<(), DeliverError> {
        let Ok(_permit) = self.in_flight.try_acquire() else {
            return Err(DeliverError::Throttled);
        };
        match timeout(PUSH_TIMEOUT, self.deliver_inner(first, device_token, request, may_switch)).await {
            Ok(result) => result,
            Err(_) => {
                self.connections.lock().unwrap().clear();
                Err(DeliverError::Unreachable("timed out".into()))
            }
        }
    }

    async fn deliver_inner(
        &self,
        first: &'static str,
        device_token: &str,
        request: &ApnsRequest,
        may_switch: bool,
    ) -> Result<(), DeliverError> {
        if self.breaker.lock().unwrap().blocked(Instant::now()) {
            return Err(DeliverError::Throttled);
        }
        let mut host = first;
        let mut switched = false;
        let mut refreshed = false;
        let mut jwt = self.jwt();
        loop {
            let attempt = self
                .attempt(host, device_token, request, &jwt)
                .await
                .map_err(|error| DeliverError::Unreachable(error.to_string()))?;
            let refusal = match attempt {
                Attempt::Accepted => {
                    self.breaker.lock().unwrap().record_success();
                    if host != first {
                        self.remember_environment(device_token, host);
                    }
                    return Ok(());
                }
                Attempt::Refused(refusal) => refusal,
            };
            if refusal.is_wrong_environment() && may_switch && !switched {
                switched = true;
                host = if host == APNS_HOST { APNS_SANDBOX_HOST } else { APNS_HOST };
                continue;
            }
            if refusal.is_stale_provider_token() && !refreshed {
                refreshed = true;
                if self.refresh_jwt(&jwt) {
                    jwt = self.jwt();
                    continue;
                }
            }
            return Err(self.settle(device_token, refusal));
        }
    }

    /// Applies what a final refusal says about the token and about Apple's mood.
    fn settle(&self, device_token: &str, refusal: ApnsRefusal) -> DeliverError {
        if refusal.is_dead_token() || refusal.is_wrong_environment() {
            self.forget_environment(device_token);
        }
        if refusal.is_throttle() || refusal.is_server_side() {
            self.breaker.lock().unwrap().record_failure(Instant::now());
        }
        warn!(device_token = %tag(device_token), refusal = %refusal, "APNs refused the push");
        if refusal.is_throttle() {
            DeliverError::Throttled
        } else {
            DeliverError::Refused(refusal)
        }
    }

    /// Replaces the provider token that Apple just called stale, unless it was replaced within
    /// the last twenty minutes, which Apple answers with `TooManyProviderTokenUpdates`.
    ///
    /// A different token already in the cache means another push refreshed it first, and counts as
    /// a refresh for this one.
    pub(super) fn refresh_jwt(&self, rejected: &str) -> bool {
        let mut guard = self.cached_jwt.lock().unwrap();
        match guard.as_ref() {
            Some(cached) if cached.token != rejected => true,
            Some(cached) if !may_refresh_jwt(cached.made_at.elapsed()) => false,
            _ => {
                *guard = None;
                drop(guard);
                self.jwt();
                true
            }
        }
    }

    async fn attempt(
        &self,
        host: &'static str,
        device_token: &str,
        request: &ApnsRequest,
        jwt: &str,
    ) -> Result<Attempt, BoxError> {
        let result = self.exchange(host, device_token, request, jwt).await;
        if result.is_err() {
            self.connections.lock().unwrap().remove(host);
        }
        result
    }

    async fn exchange(
        &self,
        host: &'static str,
        device_token: &str,
        request: &ApnsRequest,
        jwt: &str,
    ) -> Result<Attempt, BoxError> {
        let http = http_request(host, device_token, jwt, request)?;
        let payload = Bytes::from(request.body.clone().into_bytes());

        let cached = self.connections.lock().unwrap().get(host).cloned();
        let mut sender = match cached {
            Some(sender) => match sender.ready().await {
                Ok(ready) => ready,
                Err(_) => self.connect(host).await?.ready().await?,
            },
            None => self.connect(host).await?.ready().await?,
        };
        let (response, mut stream) = sender.send_request(http, false)?;
        stream.send_data(payload, true)?;

        let response = response.await?;
        let status = response.status();
        let mut body = response.into_body();
        let mut reply = Vec::new();
        while let Some(chunk) = body.data().await {
            let chunk = chunk?;
            let _ = body.flow_control().release_capacity(chunk.len());
            if reply.len() + chunk.len() > MAX_REPLY_BYTES {
                break;
            }
            reply.extend_from_slice(&chunk);
        }
        if status.is_success() {
            return Ok(Attempt::Accepted);
        }
        Ok(Attempt::Refused(ApnsRefusal::parse(status.as_u16(), &reply)))
    }

    async fn connect(&self, host: &'static str) -> Result<client::SendRequest<Bytes>, BoxError> {
        let tcp = TcpStream::connect((host, APNS_PORT)).await?;
        tcp.set_nodelay(true)?;
        let server_name = ServerName::try_from(host).map_err(|_| "invalid APNs hostname")?.to_owned();
        let tls = TlsConnector::from(Arc::clone(&self.tls_config)).connect(server_name, tcp).await?;
        let (sender, connection) = client::Builder::new().handshake::<_, Bytes>(tls).await?;
        tokio::spawn(async move {
            let _ = connection.await;
        });
        self.connections.lock().unwrap().insert(host, sender.clone());
        Ok(sender)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::apns_policy::MIN_JWT_REFRESH;
    use crate::activity::ActivityFailure;

    fn client() -> ApnsClient {
        let key = rcgen::KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256).unwrap();
        let path = std::env::temp_dir().join(format!("apns-test-{}-{:?}.p8", std::process::id(), std::thread::current().id()));
        std::fs::write(&path, key.serialize_pem()).unwrap();
        let client = ApnsClient::from_config(path.clone(), "KEYID".into(), "TEAMID".into(), "pl.example.app".into()).unwrap();
        let _ = std::fs::remove_file(path);
        client
    }

    fn age_the_token(client: &ApnsClient, age: Duration) {
        let mut guard = client.cached_jwt.lock().unwrap();
        guard.as_mut().unwrap().made_at = Instant::now().checked_sub(age).unwrap();
    }

    #[test]
    fn a_stale_provider_token_is_not_replaced_twice_within_twenty_minutes() {
        let client = client();
        let used = client.jwt();
        age_the_token(&client, Duration::from_secs(60));
        assert!(!client.refresh_jwt(&used));
        assert_eq!(client.jwt(), used);
    }

    #[test]
    fn a_provider_token_older_than_twenty_minutes_is_replaced_on_demand() {
        let client = client();
        let used = client.jwt();
        age_the_token(&client, MIN_JWT_REFRESH + Duration::from_secs(1));
        assert!(client.refresh_jwt(&used));
        assert_ne!(client.jwt(), used);
    }

    #[test]
    fn a_token_another_push_already_replaced_counts_as_refreshed() {
        let client = client();
        let current = client.jwt();
        assert!(client.refresh_jwt("an older token"));
        assert_eq!(client.jwt(), current);
    }

    #[test]
    fn a_dead_token_is_dropped_from_the_environments_map() {
        let client = client();
        client.remember_environment("abcd", APNS_SANDBOX_HOST);
        assert_eq!(client.first_host("abcd"), APNS_SANDBOX_HOST);
        let error = client.settle("abcd", ApnsRefusal { status: 410, reason: Some("Unregistered".into()) });
        assert!(matches!(error, DeliverError::Refused(_)));
        assert_eq!(client.first_host("abcd"), APNS_HOST);
    }

    #[test]
    fn a_429_is_a_throttle_and_three_in_a_row_stop_the_sending() {
        let client = client();
        let throttle = || ApnsRefusal { status: 429, reason: Some("TooManyRequests".into()) };
        for _ in 0..3 {
            assert!(matches!(client.settle("abcd", throttle()), DeliverError::Throttled));
        }
        assert!(client.breaker.lock().unwrap().blocked(Instant::now()));
    }

    #[test]
    fn server_errors_open_the_breaker_but_stay_refusals() {
        let client = client();
        for _ in 0..3 {
            let error = client.settle("abcd", ApnsRefusal { status: 503, reason: None });
            assert!(matches!(error, DeliverError::Refused(_)));
        }
        assert!(client.breaker.lock().unwrap().blocked(Instant::now()));
    }

    #[test]
    fn a_refusal_that_is_the_pushs_own_fault_leaves_the_breaker_closed() {
        let client = client();
        for _ in 0..5 {
            client.settle("abcd", ApnsRefusal { status: 400, reason: Some("BadTopic".into()) });
        }
        assert!(!client.breaker.lock().unwrap().blocked(Instant::now()));
    }

    #[tokio::test]
    async fn an_open_breaker_refuses_without_touching_the_network() {
        let client = client();
        for _ in 0..3 {
            client.breaker.lock().unwrap().record_failure(Instant::now());
        }
        let request = ApnsRequest { push_type: "alert", topic: "t".into(), priority: 10, expiration: None, body: "{}".into() };
        let result = client.deliver(APNS_HOST, "abcd", &request, true).await;
        assert!(matches!(result, Err(DeliverError::Throttled)));
    }

    #[tokio::test]
    async fn pushes_beyond_the_in_flight_limit_are_refused_not_queued() {
        let client = client();
        let _held = client.in_flight.try_acquire_many(MAX_PUSHES_IN_FLIGHT as u32).unwrap();
        let request = ApnsRequest { push_type: "alert", topic: "t".into(), priority: 10, expiration: None, body: "{}".into() };
        let result = client.deliver(APNS_HOST, "abcd", &request, true).await;
        assert!(matches!(result, Err(DeliverError::Throttled)));
    }

    #[test]
    fn delivery_errors_map_to_activity_failures() {
        let dead = ApnsRefusal { status: 410, reason: Some("Unregistered".into()) };
        assert_eq!(ActivityFailure::from(&DeliverError::Refused(dead)), ActivityFailure::TokenRejected);
        assert_eq!(ActivityFailure::from(&DeliverError::Throttled), ActivityFailure::Throttled);
        assert_eq!(ActivityFailure::from(&DeliverError::Unreachable("x".into())), ActivityFailure::Unavailable);
    }
}
