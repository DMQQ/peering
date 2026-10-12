//! Signalling: how a phone finds out where its Mac is, and how the two are handed a session.
//!
//! Presence is the connection: a Mac is online exactly while it holds a signalling WebSocket open,
//! so there is no heartbeat to tune and no stale registration to expire.

mod accept;
mod connection;
mod hosts;
mod metering;
mod notify;
mod proof;
mod referral;
mod register;
mod session;
#[cfg(test)]
mod tests;

use std::net::IpAddr;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tokio::sync::mpsc;

use crate::activity::{ActivityLimiter, SharedActivityBudget};
use crate::apns::ApnsClient;
use crate::fcm::FcmClient;
use crate::limits::PeerLimiter;
use crate::play_api::PlayVerifier;
use crate::playbilling::PlayReceiptCache;
use crate::protocol::{ClientMessage, ServerMessage};
use crate::push::PushLimiter;
use crate::quota::QuotaTracker;
use crate::session::Registry;
use crate::stats::{Refusal, TALLY};
use crate::storekit::{ReceiptCache, StoreKitVerifier};

pub use accept::serve;
pub use hosts::HostRegistry;

use proof::ProofFields;

/// IDs and names are short (device IDs are UUIDs), so a longer string is refused.
const MAX_FIELD: usize = 256;

/// How the relay describes itself to the two ends.
#[derive(Clone)]
pub struct Settings {
    /// The name clients connect back to. `None` means the address the client reached us on.
    pub host: Option<String>,
    /// The control port as clients reach it, which need not be the port the relay binds.
    pub public_control_port: u16,
    /// The one shared video port as clients must reach it. See `udp_relay`.
    pub video_port: u16,
    pub session_ttl: Duration,
    pub quota: Arc<QuotaTracker>,
    /// Decides whether a client's plan is Apple's or its own claim. See `storekit`.
    pub receipts: Arc<StoreKitVerifier>,
    /// See `Config::max_sessions`.
    pub max_sessions: usize,
    /// See `Config::max_connections`.
    pub max_connections: usize,
    /// See `Config::handshake_timeout` and `Config::idle_timeout`.
    pub handshake_timeout: Duration,
    pub idle_timeout: Duration,
    /// `None` means push notifications are unavailable and `NotifyDevice` is dropped.
    pub apns: Option<Arc<ApnsClient>>,
    /// `None` drops Android pushes.
    pub fcm: Option<Arc<FcmClient>>,
    /// `None` leaves Play purchases unread.
    pub play: Option<Arc<PlayVerifier>>,
    /// Per peer address ceilings. See `limits`.
    pub limiter: Arc<PeerLimiter>,
    /// See `Config::require_proven_hosts`.
    pub require_proven_hosts: bool,
    /// Live Activity pushes per token across every connection. See `activity::SharedActivityBudget`.
    pub activity_budget: Arc<SharedActivityBudget>,
}

/// What one signalling connection carries from message to message.
#[derive(Default)]
struct ConnectionState {
    /// The address this socket came from, or `None` where there is no per address accounting.
    peer: Option<IpAddr>,
    /// The device ID this socket registered as, so the registration can be removed when it closes.
    registered_as: Option<String>,
    /// Sessions this socket has asked for. Capped so one socket cannot spend the whole process-wide
    /// ceiling and turn it into a denial of service.
    sessions_asked_for: usize,
    /// Receipt verdicts, so a JWS is verified once per socket rather than once per message.
    receipts: ReceiptCache,
    /// Google verdicts, so Google is asked once per purchase per socket.
    play_purchases: PlayReceiptCache,
    /// Invite requests made on this socket; each costs a signature check.
    referral_requests: usize,
    activity_limiter: ActivityLimiter,
    push_limiter: PushLimiter,
}

fn unix_now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs()
}

/// An error reply, counted when it is a refusal worth tallying.
fn refuse(reason: Option<Refusal>, code: &str, message: impl Into<String>) -> ServerMessage {
    if let Some(reason) = reason {
        TALLY.refused(reason);
    }
    ServerMessage::error(code, message)
}

fn field_too_long() -> ServerMessage {
    ServerMessage::error("invalid", "field too long")
}

/// Handles one client message, returning the reply to send back to *this* connection.
async fn dispatch(
    message: ClientMessage,
    self_tx: &mpsc::Sender<ServerMessage>,
    registry: &Arc<Registry>,
    hosts: &HostRegistry,
    settings: &Settings,
    relay_host: &str,
    state: &mut ConnectionState,
) -> Option<ServerMessage> {
    match message {
        ClientMessage::RegisterHost { device_id, name, protocol_version, public_key, proof, proof_time } => {
            let registration = register::Registration {
                device_id,
                name,
                protocol_version,
                proof: ProofFields { public_key, proof, proof_time },
            };
            Some(register::register_host(registration, self_tx, hosts, settings, state).await)
        }
        ClientMessage::ConnectToHost {
            host_id,
            client_id,
            protocol_version,
            api_key,
            plan,
            jws_representation,
            public_key,
            proof,
            proof_time,
            play_purchase_token,
            play_product_id,
        } => {
            let request = session::ConnectRequest {
                host_id,
                client_id,
                protocol_version,
                api_key,
                plan,
                jws_representation,
                proof: ProofFields { public_key, proof, proof_time },
                play_purchase_token,
                play_product_id,
            };
            Some(session::connect_to_host(request, registry, hosts, settings, relay_host, state).await)
        }
        ClientMessage::RequestPeerAddress { video_token } => {
            Some(session::request_peer_address(registry, &video_token))
        }
        ClientMessage::HostPresence { host_id } => Some(session::host_presence(hosts, host_id).await),
        ClientMessage::NotifyDevice { device_token, title, body, source, category, session_id, approval_id } => {
            let notice = notify::DeviceNotice { device_token, title, body, source, category, session_id, approval_id };
            notify::notify_device(notice, settings, state)
        }
        ClientMessage::NotifyActivity(push) => notify::notify_activity_from_host(push, self_tx, settings, state),
        ClientMessage::ReferralStatus { client_id, public_key, proof, proof_time } => {
            let proof = ProofFields { public_key, proof, proof_time };
            Some(referral::status(client_id, &proof, settings, state))
        }
        ClientMessage::RedeemReferral { client_id, code, public_key, proof, proof_time } => {
            let proof = ProofFields { public_key, proof, proof_time };
            Some(referral::redeem(client_id, code, &proof, settings, state))
        }
        ClientMessage::Ping => Some(ServerMessage::Pong),
    }
}
