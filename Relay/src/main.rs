use std::fs::File;
use std::io::BufReader;
use std::sync::Arc;
use std::time::Duration;

use tokio::net::TcpListener;
use tokio_rustls::rustls::ServerConfig;
use tokio_rustls::TlsAcceptor;
use tracing::{info, warn};
use tracing_subscriber::EnvFilter;

use peeringd::config::{Config, TlsFiles};
use peeringd::quota::QuotaTracker;
use peeringd::session::Registry;
use peeringd::signalling::{HostRegistry, Settings};
use peeringd::storekit::StoreKitVerifier;
use peeringd::udp_relay::PortPool;
use peeringd::{signalling, tcp_relay, web};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let config = Config::from_env()?;
    let registry = Arc::new(Registry::new());
    let hosts = HostRegistry::new();

    let tls = match &config.tls {
        Some(files) => Some(acceptor(files)?),
        None => {
            warn!("signalling is running without TLS — fine on loopback, never on a public address");
            None
        }
    };

    // The control relay is plain TCP on purpose, and it is worth being clear that this is not a gap
    // to be closed later: terminating TLS here would mean the relay could read the control channel,
    // and end-to-end confidentiality is the whole property being sold.
    let quota = Arc::new(QuotaTracker::new(config.plans, config.paid_keys.clone()));

    // The one thing here that is not about bandwidth: whether a plan is Apple's or the client's.
    // Built once, holds no state that outlives a session, and reaches nowhere — see `storekit`.
    let receipts = Arc::new(StoreKitVerifier::apple(config.trust_claimed_plans));

    // The allowances are logged as minutes because that is how they are configured and how the
    // app's copy states them; seconds would be a conversion nobody asked for. `unlimited` is the
    // top two plans and is not configurable — see `PlanAllowances`.
    info!(
        free_minutes = config.plans.free_seconds.map(|s| s / 60),
        relay_minutes = config.plans.relay_seconds.map(|s| s / 60),
        "relay quota active; the plan comes from the receipt Apple signed, and from the plan the client claims when there is no receipt that verifies"
    );

    // Said at startup rather than only in a comment, because it is the state of the one known hole
    // in the relay and the line an operator should see before deciding it is fine. Read off the
    // verifier rather than off the configuration, so the warning is about what was actually built.
    if receipts.trusts_claims() {
        warn!(
            "a client with no verifiable receipt is metered by the plan it claims, which a patched app can lie about; set PEERINGD_TRUST_CLAIMED_PLANS=0 to meter every unproven plan as free"
        );
    } else {
        info!(
            "claimed plans are not trusted: only a receipt that verifies against Apple's root buys more than the free allowance"
        );
    }

    if config.plans.free_seconds == Some(0) {
        info!("relay is gated — clients on the free plan cannot use relay (PEERINGD_FREE_MINUTES=0)");
    }

    let control = TcpListener::bind(config.control_addr).await?;
    let signal = TcpListener::bind(config.signal_addr).await?;

    tokio::spawn(tcp_relay::serve(control, Arc::clone(&registry), Arc::clone(&quota)));

    // Abandoned sessions are the normal residue of clients that crash or walk away, so this runs
    // forever rather than as a one-off. A session holds a bound UDP socket, so letting them
    // accumulate would leak file descriptors, not just memory.
    let sweep_registry = Arc::clone(&registry);
    let ttl = config.session_ttl;
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(30));
        loop {
            ticker.tick().await;
            let swept = sweep_registry.sweep(ttl).await;
            if swept > 0 {
                info!(swept, "swept abandoned sessions");
            }
        }
    });

    let video_ports = Arc::new(PortPool::new(config.video_ports));

    // The video range is logged at startup because it is the number that has to match the firewall,
    // and a mismatch shows up as "control works, video never arrives" — which is far harder to
    // diagnose from the symptom than from this line.
    match video_ports.range() {
        Some(range) => info!(
            video_ports = %format!("{}-{} ({} ports)", range.first, range.last, range.len()),
            "video will use a fixed port range — open exactly these"
        ),
        None => warn!(
            "no PEERINGD_VIDEO_PORTS range set, so session video ports are chosen by the OS from \
             the entire ephemeral range; a firewall must allow all of it"
        ),
    }

    info!(
        control = %config.control_addr,
        signal = %config.signal_addr,
        video_bind = %config.video_bind,
        session_ttl_seconds = config.session_ttl.as_secs(),
        "peeringd ready"
    );

    // The site, if there is one. Binds its own listener, which fails soft: a relay deployed
    // without a `site` directory is a perfectly good relay, and should not refuse to start over a
    // missing landing page.
    if let Some((listener, root)) = web::bind(config.web_addr, config.web_root.clone()).await {
        tokio::spawn(web::serve(listener, Arc::new(root)));
    }

    let settings = Settings {
        host: config.public_host.clone(),
        // Falls back to the bound port, which is right whenever nothing is forwarded.
        public_control_port: config
            .public_control_port
            .unwrap_or_else(|| config.control_addr.port()),
        video_bind: config.video_bind,
        video_ports,
        public_video_port: config.public_video_port,
        session_ttl: config.session_ttl,
        quota,
        receipts,
    };

    tokio::select! {
        _ = signalling::serve(signal, Arc::clone(&registry), hosts, settings, tls) => {}
        _ = tokio::signal::ctrl_c() => info!("stopping"),
    }

    Ok(())
}

fn acceptor(files: &TlsFiles) -> Result<TlsAcceptor, Box<dyn std::error::Error>> {
    let certificates = rustls_pemfile::certs(&mut BufReader::new(File::open(&files.cert)?))
        .collect::<Result<Vec<_>, _>>()?;
    if certificates.is_empty() {
        return Err(format!("no certificates found in {}", files.cert.display()).into());
    }

    let key = rustls_pemfile::private_key(&mut BufReader::new(File::open(&files.key)?))?
        .ok_or_else(|| format!("no private key found in {}", files.key.display()))?;

    // The provider is named explicitly rather than left to `ServerConfig::builder()`, which picks
    // whatever the feature flags happen to have installed. Naming it means this keeps working if
    // the dependency graph ever grows a second provider, which would otherwise turn into a runtime
    // panic on the first connection.
    let provider = Arc::new(tokio_rustls::rustls::crypto::ring::default_provider());

    let config = ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()?
        .with_no_client_auth()
        .with_single_cert(certificates, key)?;

    Ok(TlsAcceptor::from(Arc::new(config)))
}
