//! Pushes to Android devices through Firebase Cloud Messaging HTTP v1.
//!
//! A push is one POST to `messages:send` with a bearer token from `fcm_auth`. The body mirrors the
//! APNs payload: the same title and body, the same route keys, and the same category for an
//! approval, carried as FCM `data` because FCM has no `aps` dictionary. Unlike APNs, a token FCM
//! reports as unregistered is an outcome to act on rather than an error, so the device can be
//! forgotten.

pub(crate) mod https;
#[cfg(test)]
mod tests;

use std::future::Future;
use std::path::Path;
use std::pin::Pin;
use std::sync::{Arc, Mutex};

use bytes::Bytes;
use http::Method;
use serde_json::{Map, Value, json};
use tracing::warn;

use crate::apns::PushRoute;
use crate::fcm_auth::{AccessTokenCache, BoxError, Clock, FCM_SCOPE, HttpTokenExchange, ServiceAccount, SystemClock, TokenExchange};

const FCM_ORIGIN: &str = "https://fcm.googleapis.com";

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// The HTTP v1 request body for one notification.
pub struct FcmMessage;

impl FcmMessage {
    pub fn build(token: &str, title: &str, body: &str, route: Option<PushRoute<'_>>) -> Value {
        let mut message = json!({
            "token": token,
            "notification": {"title": title, "body": body},
            "android": {"priority": "HIGH"},
        });
        let data = data_for(route);
        if !data.is_empty() {
            message["data"] = Value::Object(data);
        }
        json!({"message": message})
    }
}

fn data_for(route: Option<PushRoute<'_>>) -> Map<String, Value> {
    let mut data = Map::new();
    let Some(route) = route else {
        return data;
    };
    data.insert("hostId".to_owned(), route.host_id.into());
    if let Some(source) = route.source {
        data.insert("source".to_owned(), source.into());
    }
    if let Some(action) = route.action {
        data.insert("category".to_owned(), action.category.into());
        data.insert("agentSessionId".to_owned(), action.session_id.into());
        data.insert("agentApprovalId".to_owned(), action.approval_id.into());
    }
    data
}

pub struct FcmReply {
    pub status: u16,
    pub body: String,
}

/// Posts one JSON body with a bearer token. `FakeFcmTransport` answers in tests.
pub trait FcmTransport: Send + Sync {
    fn post<'a>(&'a self, url: &'a str, bearer: &'a str, body: &'a str) -> BoxFuture<'a, Result<FcmReply, BoxError>>;
}

/// The production transport: HTTP/2 over TLS to `fcm.googleapis.com`.
pub struct HttpsFcmTransport {
    tls: Arc<tokio_rustls::rustls::ClientConfig>,
}

impl FcmTransport for HttpsFcmTransport {
    fn post<'a>(&'a self, url: &'a str, bearer: &'a str, body: &'a str) -> BoxFuture<'a, Result<FcmReply, BoxError>> {
        Box::pin(async move {
            let authorization = format!("Bearer {bearer}");
            let reply = https::request(
                &self.tls,
                Method::POST,
                url,
                &[("authorization", authorization.as_str()), ("content-type", "application/json")],
                Bytes::copy_from_slice(body.as_bytes()),
            )
            .await?;
            Ok(FcmReply { status: reply.status, body: reply.body })
        })
    }
}

/// Where the bearer token for a push comes from.
pub trait AccessTokens: Send + Sync {
    fn token(&self) -> BoxFuture<'_, Result<String, BoxError>>;
}

impl<C: Clock, E: TokenExchange> AccessTokens for AccessTokenCache<C, E> {
    fn token(&self) -> BoxFuture<'_, Result<String, BoxError>> {
        Box::pin(self.access_token())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FcmOutcome {
    Accepted,
    /// FCM no longer knows this registration token. The device has uninstalled or reset the app.
    Unregistered,
}

pub struct FcmClient {
    project_id: String,
    tokens: Box<dyn AccessTokens>,
    transport: Box<dyn FcmTransport>,
}

impl FcmClient {
    pub fn new(
        project_id: String,
        tokens: impl AccessTokens + 'static,
        transport: impl FcmTransport + 'static,
    ) -> Self {
        Self {
            project_id,
            tokens: Box::new(tokens),
            transport: Box::new(transport),
        }
    }

    /// The client the relay runs with, built from the service account file: tokens minted from its
    /// key and sent over HTTPS. `project_id` overrides the project the file names.
    pub fn from_service_account_file(path: &Path, project_id: Option<String>) -> Result<Self, BoxError> {
        let account = ServiceAccount::from_file(path)?;
        let project_id = project_id.unwrap_or_else(|| account.project_id().to_owned());
        let tls = https::tls_config()?;
        let exchange = HttpTokenExchange::new(account.token_uri().to_owned(), Arc::clone(&tls));
        let tokens = AccessTokenCache::new(account, FCM_SCOPE, exchange, SystemClock);
        Ok(Self::new(project_id, tokens, HttpsFcmTransport { tls }))
    }

    pub async fn send(
        &self,
        device_token: &str,
        title: &str,
        body: &str,
        route: Option<PushRoute<'_>>,
    ) -> Result<FcmOutcome, BoxError> {
        let bearer = self.tokens.token().await?;
        let url = format!("{FCM_ORIGIN}/v1/projects/{}/messages:send", self.project_id);
        let payload = FcmMessage::build(device_token, title, body, route).to_string();
        let reply = self.transport.post(&url, &bearer, &payload).await?;
        classify(reply)
    }
}

fn classify(reply: FcmReply) -> Result<FcmOutcome, BoxError> {
    if (200..300).contains(&reply.status) {
        return Ok(FcmOutcome::Accepted);
    }
    if reply.status == 404 || reply.body.contains("UNREGISTERED") {
        warn!(status = reply.status, "FCM reports the device token is no longer registered");
        return Ok(FcmOutcome::Unregistered);
    }
    Err(format!("FCM refused the push with status {}", reply.status).into())
}

/// The sends a `FakeFcmTransport` was asked for, shared with the test that made it.
pub type SentPosts = Arc<Mutex<Vec<SentPost>>>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SentPost {
    pub url: String,
    pub bearer: String,
    pub body: String,
}

/// Records each post and answers with one fixed status and body.
pub struct FakeFcmTransport {
    status: u16,
    body: String,
    sent: SentPosts,
}

impl FakeFcmTransport {
    pub fn answering(status: u16, body: &str) -> (Self, SentPosts) {
        let sent: SentPosts = Arc::new(Mutex::new(Vec::new()));
        let transport = Self { status, body: body.to_owned(), sent: Arc::clone(&sent) };
        (transport, sent)
    }
}

impl FcmTransport for FakeFcmTransport {
    fn post<'a>(&'a self, url: &'a str, bearer: &'a str, body: &'a str) -> BoxFuture<'a, Result<FcmReply, BoxError>> {
        self.sent.lock().unwrap().push(SentPost {
            url: url.to_owned(),
            bearer: bearer.to_owned(),
            body: body.to_owned(),
        });
        let reply = FcmReply { status: self.status, body: self.body.clone() };
        Box::pin(async move { Ok(reply) })
    }
}

/// Hands out a fixed bearer token, or refuses to.
pub struct FakeAccessTokens {
    token: Result<String, String>,
}

impl FakeAccessTokens {
    pub fn giving(token: &str) -> Self {
        Self { token: Ok(token.to_owned()) }
    }

    pub fn refusing(message: &str) -> Self {
        Self { token: Err(message.to_owned()) }
    }
}

impl AccessTokens for FakeAccessTokens {
    fn token(&self) -> BoxFuture<'_, Result<String, BoxError>> {
        let answer = self.token.clone().map_err(BoxError::from);
        Box::pin(async move { answer })
    }
}
