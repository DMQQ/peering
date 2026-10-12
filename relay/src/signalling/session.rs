//! A phone asking for a session with a Mac, and the smaller questions asked beside it.

use std::sync::Arc;

use tokio::time;
use tracing::{info, warn};

use super::hosts::HostRef;
use super::metering::{meter, metered_key, Metering};
use super::proof::ProofFields;
use super::{field_too_long, refuse, ConnectionState, HostRegistry, Settings, MAX_FIELD};
use crate::limits::Permit;
use crate::protocol::{hex, unhex, ServerMessage};
use crate::quota::Plan;
use crate::redact::tag;
use crate::session::{Allocated, Registry, Token, CLIENT_SLOT, HOST_SLOT};
use crate::stats::{Refusal, TALLY};

/// How many sessions one signalling connection may ask for. Past it the client is in a loop.
const MAX_SESSIONS_PER_CONNECTION: usize = 64;

pub(super) struct ConnectRequest {
    pub host_id: String,
    pub client_id: String,
    pub protocol_version: u16,
    pub api_key: Option<String>,
    pub plan: Option<String>,
    pub jws_representation: Option<String>,
    pub proof: ProofFields,
    pub play_purchase_token: Option<String>,
    pub play_product_id: Option<String>,
}

pub(super) async fn connect_to_host(
    request: ConnectRequest,
    registry: &Arc<Registry>,
    hosts: &HostRegistry,
    settings: &Settings,
    relay_host: &str,
    state: &mut ConnectionState,
) -> ServerMessage {
    match try_connect(request, registry, hosts, settings, relay_host, state).await {
        Ok(reply) | Err(reply) => reply,
    }
}

async fn try_connect(
    request: ConnectRequest,
    registry: &Arc<Registry>,
    hosts: &HostRegistry,
    settings: &Settings,
    relay_host: &str,
    state: &mut ConnectionState,
) -> Result<ServerMessage, ServerMessage> {
    check_field_lengths(&request)?;
    let ConnectRequest { host_id, client_id, protocol_version, api_key, .. } = &request;

    let key = metered_key(&request.proof, client_id);
    let metered_as = key.as_deref().unwrap_or(client_id);
    let metering = resolve_metering(settings, state, &request, key.as_deref()).await;
    let remaining = check_allowance(settings, &request, metered_as, &metering)?;

    let host = find_host(hosts, settings, host_id).await?;
    // A courtesy so a mismatched pair is told before either end spends a round trip on a handshake
    // that would fail anyway; the two ends check again themselves.
    if host.protocol_version != *protocol_version {
        return Err(refuse(
            Some(Refusal::VersionMismatch),
            "version",
            format!("host speaks v{}, client speaks v{protocol_version}", host.protocol_version),
        ));
    }

    let unspliced = admit_allocation(settings, state, client_id)?;
    let account = settings.quota.account(metered_as, api_key.as_deref(), metering.plan);
    let Some(allocated) = registry.allocate_guarded(host_id, client_id, account, unspliced).await else {
        // Read first: an `.await` inside a tracing macro's fields makes the future non-`Send`.
        let sessions = registry.len().await;
        warn!(client_id = %tag(client_id), sessions, "refused: the relay is at its session ceiling");
        return Err(refuse(None, "relayFull", "the relay is at capacity; try again in a minute"));
    };

    TALLY.session_allocated();
    info!(
        host_id = %tag(host_id),
        client_id = %tag(client_id),
        metered_by = if key.is_some() { "key" } else { "id" },
        video_port = settings.video_port,
        plan = metering.plan.as_str(),
        plan_trust = metering.trust.as_str(),
        "session allocated"
    );
    let ready = |video_token: Token| session_ready(&allocated, video_token, settings, relay_host, remaining);
    deliver(registry, &host, host_id, &allocated, settings, ready).await
}

/// The Mac hears first. A failed push means it left between registering and now, which is reported
/// to the phone instead of leaving it waiting on a session nobody will join.
async fn deliver(
    registry: &Arc<Registry>,
    host: &HostRef,
    host_id: &str,
    allocated: &Allocated,
    settings: &Settings,
    ready: impl Fn(Token) -> ServerMessage,
) -> Result<ServerMessage, ServerMessage> {
    let delivered = time::timeout(settings.handshake_timeout, host.tx.send(ready(allocated.video_tokens[HOST_SLOT]))).await;
    if !matches!(delivered, Ok(Ok(()))) {
        warn!(host_id = %tag(host_id), "host went away while its session was being set up");
        registry.release(&allocated.control_token).await;
        TALLY.refused(Refusal::HostOffline);
        return Err(ServerMessage::HostOffline { device_id: host_id.to_string() });
    }
    Ok(ready(allocated.video_tokens[CLIENT_SLOT]))
}

fn check_field_lengths(request: &ConnectRequest) -> Result<(), ServerMessage> {
    let too_long = request.host_id.len() > MAX_FIELD
        || request.client_id.len() > MAX_FIELD
        || request.api_key.as_ref().is_some_and(|key| key.len() > MAX_FIELD);
    if too_long { Err(field_too_long()) } else { Ok(()) }
}

/// Resolves the plan before anything is allocated; what travels on is the resolved plan, never a
/// raw name or an unverified receipt. The receipt is never logged.
async fn resolve_metering(
    settings: &Settings,
    state: &mut ConnectionState,
    request: &ConnectRequest,
    key: Option<&str>,
) -> Metering {
    let play = match (request.play_purchase_token.as_deref(), request.play_product_id.as_deref()) {
        (Some(token), Some(product)) => Some((token, product)),
        _ => None,
    };
    let claimed = Plan::from_wire(request.plan.as_deref());
    let metering = meter(settings, state, claimed, request.jws_representation.as_deref(), play, key).await;
    // The answer to "why is this client metered as free": `not_a_real_purchase` is a TestFlight
    // sandbox receipt, which is refused by name whatever the switch says.
    if let Some(reason) = metering.refused {
        info!(
            client_id = %tag(&request.client_id),
            plan = metering.plan.as_str(),
            plan_trust = metering.trust.as_str(),
            reason,
            "receipt refused"
        );
    }
    metering
}

/// Seconds left in the allowance, or a refusal when it is spent. This only answers for the instant
/// the session is handed out; `tcp_relay` charges the same counter while the splice runs.
fn check_allowance(
    settings: &Settings,
    request: &ConnectRequest,
    metered_as: &str,
    metering: &Metering,
) -> Result<Option<u64>, ServerMessage> {
    let remaining = settings.quota.remaining(metered_as, request.api_key.as_deref(), metering.plan);
    if remaining == Some(0) {
        info!(
            client_id = %tag(&request.client_id),
            plan = metering.plan.as_str(),
            plan_trust = metering.trust.as_str(),
            "relay allowance exhausted"
        );
        return Err(refuse(
            Some(Refusal::QuotaRefusedAtConnect),
            "quotaExceeded",
            "relay allowance exhausted for this period",
        ));
    }
    Ok(remaining)
}

async fn find_host(
    hosts: &HostRegistry,
    settings: &Settings,
    host_id: &str,
) -> Result<HostRef, ServerMessage> {
    let offline = || ServerMessage::HostOffline { device_id: host_id.to_string() };
    let Some(host) = hosts.entry_for(host_id).await else {
        TALLY.refused(Refusal::HostNotRegistered);
        info!(host_id = %tag(host_id), "asked for a host that is not registered");
        return Err(offline());
    };
    // A host that only named its id cannot be told from one invented to soak up sessions.
    if settings.require_proven_hosts && !host.proven {
        TALLY.refused(Refusal::HostNotRegistered);
        info!(host_id = %tag(host_id), "asked for a host that has not proved its key");
        return Err(offline());
    }
    Ok(host)
}

/// The per connection ceiling first, being the cheaper answer, then the per address rate and the
/// unspliced cap. The permit holds the unspliced slot until both control ends have joined.
fn admit_allocation(
    settings: &Settings,
    state: &mut ConnectionState,
    client_id: &str,
) -> Result<Option<Permit>, ServerMessage> {
    if state.sessions_asked_for >= MAX_SESSIONS_PER_CONNECTION {
        warn!(client_id = %tag(client_id), "refused: one connection has asked for too many sessions");
        return Err(refuse(
            None,
            "tooManySessions",
            "this connection has asked for too many sessions; reconnect to try again",
        ));
    }
    let unspliced = match state.peer {
        Some(ip) => {
            if !settings.limiter.allow_allocation(ip) {
                warn!(client_id = %tag(client_id), "refused: this address is allocating sessions too fast");
                return Err(refuse(
                    Some(Refusal::PerIpLimit),
                    "tooManySessions",
                    "too many sessions from this address; try again in a minute",
                ));
            }
            let Some(permit) = settings.limiter.admit_unspliced(ip) else {
                warn!(client_id = %tag(client_id), "refused: this address has too many sessions nobody has joined");
                return Err(refuse(
                    Some(Refusal::PerIpLimit),
                    "tooManySessions",
                    "too many unfinished sessions from this address; try again shortly",
                ));
            };
            Some(permit)
        }
        None => None,
    };
    state.sessions_asked_for += 1;
    Ok(unspliced)
}

/// The two ends get different video tokens (the shared video socket routes on them); the control
/// token is shared because each side presents it once and it is used up.
fn session_ready(
    allocated: &Allocated,
    video_token: Token,
    settings: &Settings,
    relay_host: &str,
    remaining: Option<u64>,
) -> ServerMessage {
    ServerMessage::SessionReady {
        control_host: relay_host.to_string(),
        control_port: settings.public_control_port,
        video_host: relay_host.to_string(),
        video_port: settings.video_port,
        control_token: hex(&allocated.control_token),
        video_token: hex(&video_token),
        remaining_seconds: remaining,
    }
}

/// One end asking where the other is. A read of what the datagram path already knows, and not a
/// wait: "the peer has not spoken yet" is reported rather than parked on. It is an observation, not
/// a promise; the two ends settle whether the path works by trying it.
pub(super) fn request_peer_address(registry: &Arc<Registry>, video_token: &str) -> ServerMessage {
    let Some(token) = unhex(video_token) else {
        return ServerMessage::error("invalid", "video token is not 16 bytes of hex");
    };
    match registry.routes().peer_address(&token) {
        Some(address) => ServerMessage::PeerAddress { host: address.ip().to_string(), port: address.port() },
        None => ServerMessage::error("peerAddressUnknown", "the other end of this session has not sent a datagram yet"),
    }
}

/// The lookup `ConnectToHost` does, asked as a question, without its version check. Unrated: it is
/// a hashmap lookup on a key the client must already know, and device ids are UUIDs.
pub(super) async fn host_presence(hosts: &HostRegistry, host_id: String) -> ServerMessage {
    let online = hosts.entry_for(&host_id).await.is_some();
    ServerMessage::HostPresence { host_id, online }
}
