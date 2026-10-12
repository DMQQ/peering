//! Builds the relay's parts from its configuration and says at startup what each one is doing.

use std::fmt::Display;
use std::fs::File;
use std::io::BufReader;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use tokio_rustls::rustls::ServerConfig;
use tokio_rustls::TlsAcceptor;
use tracing::{info, warn};

use peeringd::apns::ApnsClient;
use peeringd::config::{Config, TlsFiles};
use peeringd::fcm::FcmClient;
use peeringd::limits::PeerLimiter;
use peeringd::play_api::PlayVerifier;
use peeringd::quota::QuotaTracker;
use peeringd::referrals::Referrals;
use peeringd::signalling::{HostRegistry, Settings};
use peeringd::storekit::StoreKitVerifier;

/// How a file backed store is reported at startup.
struct StoreNotes {
    persisted: &'static str,
    failed: &'static str,
    unset: &'static str,
}

fn report_store(path: Option<&PathBuf>, failure: Option<&std::io::Error>, notes: &StoreNotes) {
    match (path, failure) {
        (Some(path), None) => info!(path = %path.display(), "{}", notes.persisted),
        (Some(path), Some(error)) => warn!(path = %path.display(), %error, "{}", notes.failed),
        (None, _) => warn!("{}", notes.unset),
    }
}

pub(crate) fn build_hosts(config: &Config) -> HostRegistry {
    let (hosts, failure) = HostRegistry::with_bindings(config.device_bindings.clone(), config.device_bindings_max);
    report_store(
        config.device_bindings.as_ref(),
        failure.as_ref(),
        &StoreNotes {
            persisted: "device bindings are persisted; a restart will not forget them",
            failed: "the device binding store could not be opened; bindings are in memory and a restart will forget them",
            unset: "PEERINGD_DEVICE_BINDINGS is unset; bindings are in memory and a restart will forget which device proved which id",
        },
    );
    hosts
}

pub(crate) fn build_quota(config: &Config) -> Arc<QuotaTracker> {
    let (quota, usage_failure) =
        QuotaTracker::with_usage_log(config.plans, config.paid_keys.clone(), config.usage_log.clone());
    let (referrals, referrals_failure) = Referrals::open(config.referral_terms, config.referrals.clone());
    report_store(
        config.referrals.as_ref(),
        referrals_failure.as_ref(),
        &StoreNotes {
            persisted: "invite codes are persisted; a restart will not forget them",
            failed: "the invite store could not be opened; invites are in memory and a restart will forget them",
            unset: "PEERINGD_REFERRALS is unset; invites are in memory and a restart lets every device redeem again",
        },
    );
    report_store(
        config.usage_log.as_ref(),
        usage_failure.as_ref(),
        &StoreNotes {
            persisted: "relay usage is persisted; a restart will not reset it",
            failed: "the usage log could not be opened; usage is in memory and a restart will reset it",
            unset: "PEERINGD_USAGE_LOG is unset; usage is in memory and a restart gives every client a fresh allowance",
        },
    );
    Arc::new(quota.with_referrals(Arc::new(referrals)))
}

pub(crate) fn build_tls(config: &Config) -> Result<Option<TlsAcceptor>, Box<dyn std::error::Error>> {
    match &config.tls {
        Some(files) => Ok(Some(acceptor(files)?)),
        None => {
            warn!("signalling is running without TLS: fine on loopback, never on a public address");
            Ok(None)
        }
    }
}

pub(crate) fn log_plan_policy(config: &Config, receipts: &StoreKitVerifier) {
    info!(
        free_minutes = config.plans.free_seconds.map(|s| s / 60),
        relay_minutes = config.plans.relay_seconds.map(|s| s / 60),
        "relay quota active"
    );
    if receipts.trusts_claims() {
        warn!(
            "PEERINGD_TRUST_CLAIMED_PLANS is on: a client with no verifiable receipt is metered by the plan it claims, which any patched app can lie about. That setting is for beta testing, where a TestFlight build's receipt is a sandbox one and is refused by name; unset it for production"
        );
    } else {
        info!(
            "claimed plans buy nothing: a plan is believed only when the receipt Apple signed for it verifies, and every client without one, a TestFlight build whose receipt is a sandbox one included, is metered as free"
        );
    }
    if config.plans.free_seconds == Some(0) {
        info!("relay is gated: clients on the free plan cannot use relay (PEERINGD_FREE_MINUTES=0)");
    }
}

pub(crate) fn log_video(config: &Config, video: SocketAddr) {
    info!(
        video_bind = %video,
        video_public = config.public_video_port.unwrap_or(video.port()),
        "video is one shared UDP port, however many sessions run at once; this is the one to open"
    );
    if let Some(range) = &config.stale_video_ports {
        warn!(
            peeringd_video_ports = %range,
            peeringd_video_bind = %config.video_bind,
            "PEERINGD_VIDEO_PORTS is ignored: sessions no longer have video ports of their own, so there is no range to allocate from. Put the port you forward in PEERINGD_VIDEO_BIND, and in PEERINGD_PUBLIC_VIDEO_PORT if clients reach it on a different one; this line can be deleted from the environment file"
        );
    }
}

/// Builds an optional backend: `None` input is "not configured" (logged as `disabled` when given),
/// and a failed build is logged and leaves the backend off rather than stopping the relay.
fn init_optional<T, E: Display>(
    attempt: Option<Result<T, E>>,
    ready: &str,
    failed: &str,
    disabled: Option<&str>,
) -> Option<Arc<T>> {
    match attempt {
        Some(Ok(client)) => {
            info!("{ready}");
            Some(Arc::new(client))
        }
        Some(Err(error)) => {
            warn!(%error, "{failed}");
            None
        }
        None => {
            if let Some(disabled) = disabled {
                info!("{disabled}");
            }
            None
        }
    }
}

fn build_apns(config: &Config) -> Option<Arc<ApnsClient>> {
    let attempt = match (
        config.apns_key_id.clone(),
        config.apns_team_id.clone(),
        config.apns_bundle_id.clone(),
        config.apns_key.clone(),
    ) {
        (Some(key_id), Some(team_id), Some(bundle_id), Some(key_path)) => {
            Some(ApnsClient::from_config(key_path, key_id, team_id, bundle_id))
        }
        _ => {
            let missing = config.missing_apns_settings();
            if !missing.is_empty() {
                warn!(missing = ?missing, "APNs is only partly configured, so iPhone pushes are OFF");
            }
            None
        }
    };
    init_optional(attempt, "APNs client ready", "APNs client failed to initialise; push notifications will not work", None)
}

fn build_fcm(config: &Config) -> Option<Arc<FcmClient>> {
    let attempt = config
        .fcm_service_account
        .as_ref()
        .map(|path| FcmClient::from_service_account_file(path, config.fcm_project_id.clone()));
    init_optional(
        attempt,
        "FCM client ready",
        "FCM client failed to initialise; Android pushes will not work",
        Some("FCM disabled: PEERINGD_FCM_SERVICE_ACCOUNT is not set"),
    )
}

fn build_play(config: &Config) -> Option<Arc<PlayVerifier>> {
    let attempt = match (&config.play_package, &config.play_service_account) {
        (Some(package), Some(path)) => Some(PlayVerifier::from_service_account_file(package.clone(), path)),
        _ => None,
    };
    init_optional(
        attempt,
        "Play purchase verification ready",
        "Play verifier failed to initialise; Play purchases will be metered as free",
        Some("Play purchase verification disabled: PEERINGD_PLAY_PACKAGE and PEERINGD_PLAY_SERVICE_ACCOUNT are not both set"),
    )
}

pub(crate) fn build_settings(
    config: &Config,
    quota: Arc<QuotaTracker>,
    receipts: Arc<StoreKitVerifier>,
    limiter: Arc<PeerLimiter>,
    bound_video_port: u16,
) -> Settings {
    Settings {
        host: config.public_host.clone(),
        public_control_port: config.public_control_port.unwrap_or_else(|| config.control_addr.port()),
        // The bound port, so `PEERINGD_VIDEO_BIND=0.0.0.0:0` still tells clients somewhere reachable.
        video_port: config.public_video_port.unwrap_or(bound_video_port),
        session_ttl: config.session_ttl,
        quota,
        receipts,
        max_sessions: config.max_sessions,
        max_connections: config.max_connections,
        handshake_timeout: config.handshake_timeout,
        idle_timeout: config.idle_timeout,
        apns: build_apns(config),
        fcm: build_fcm(config),
        play: build_play(config),
        limiter,
        require_proven_hosts: config.require_proven_hosts,
        activity_budget: Default::default(),
    }
}

fn acceptor(files: &TlsFiles) -> Result<TlsAcceptor, Box<dyn std::error::Error>> {
    let certificates = rustls_pemfile::certs(&mut BufReader::new(File::open(&files.cert)?))
        .collect::<Result<Vec<_>, _>>()?;
    if certificates.is_empty() {
        return Err(format!("no certificates found in {}", files.cert.display()).into());
    }

    let key = rustls_pemfile::private_key(&mut BufReader::new(File::open(&files.key)?))?
        .ok_or_else(|| format!("no private key found in {}", files.key.display()))?;

    // Named explicitly: `ServerConfig::builder()` panics on the first connection if the dependency
    // graph ever grows a second crypto provider.
    let provider = Arc::new(tokio_rustls::rustls::crypto::ring::default_provider());

    let config = ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()?
        .with_no_client_auth()
        .with_single_cert(certificates, key)?;

    Ok(TlsAcceptor::from(Arc::new(config)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_backend_that_builds_is_kept() {
        assert_eq!(init_optional(Some(Ok::<_, String>(7)), "up", "down", None).as_deref(), Some(&7));
    }

    #[test]
    fn a_backend_that_fails_or_is_not_configured_is_left_off() {
        assert!(init_optional(Some(Err::<u8, _>("broken")), "up", "down", None).is_none());
        assert!(init_optional(None::<Result<u8, String>>, "up", "down", Some("off")).is_none());
    }
}
