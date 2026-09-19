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
use peeringd::{signalling, tcp_relay, udp_relay, web};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let config = Config::from_env()?;
    let registry = Arc::new(Registry::new());
    // Who each device id belongs to. A relay that does not write these down forgets them on
    // restart, which re-opens the window for every id it had learned. See `device_bindings`.
    let (hosts, binding_failure) = HostRegistry::with_bindings(config.device_bindings.clone());
    match (&config.device_bindings, &binding_failure) {
        (Some(path), None) => {
            info!(path = %path.display(), "device bindings are persisted; a restart will not forget them")
        }
        (Some(path), Some(error)) => warn!(
            path = %path.display(),
            %error,
            "the device binding store could not be opened; bindings are in memory and a restart will forget them"
        ),
        (None, _) => warn!(
            "PEERINGD_DEVICE_BINDINGS is unset; bindings are in memory and a restart will forget which device proved which id"
        ),
    }

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
    // The counter's home, which is a file when one was named and the process's own memory
    // otherwise. Both are legal and the difference is said out loud below rather than left for an
    // operator to discover by watching a restart hand everyone their allowance back.
    let (quota, usage_log_failure) = QuotaTracker::with_usage_log(
        config.plans,
        config.paid_keys.clone(),
        config.usage_log.clone(),
    );
    let quota = Arc::new(quota);

    match (&config.usage_log, &usage_log_failure) {
        (Some(path), None) => {
            info!(path = %path.display(), "relay usage is persisted; a restart will not reset it")
        }
        (Some(path), Some(error)) => warn!(
            path = %path.display(),
            %error,
            "the usage log could not be opened; usage is in memory and a restart will reset it"
        ),
        (None, _) => warn!(
            "PEERINGD_USAGE_LOG is unset; usage is in memory and a restart gives every client a fresh allowance"
        ),
    }

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

    // The video socket, bound once here and shared by every session: the port is a property of the
    // relay now rather than of a session, so it is decided before the first one exists and never
    // again. Failing to bind is fatal and deliberately so — a relay that starts without video would
    // hand out sessions whose video silently goes nowhere, which is the hardest kind of fault to
    // read from the phone's end of it.
    let video = udp_relay::serve(
        config.video_bind,
        registry.routes(),
        config.session_ttl,
    )
    .await?;

    // What a firewall rule has to allow, and it is one port for the whole relay however many
    // sessions run at once. This line is the replacement for the old one about a range, and it is
    // the number an operator has to forward on a shared address.
    info!(
        video_bind = %video,
        video_public = config.public_video_port.unwrap_or(video.port()),
        "video is one shared UDP port, however many sessions run at once; this is the one to open"
    );

    // The range that used to be here. It is read from the environment and ignored — see the field —
    // and it is said out loud rather than dropped, because an operator who still believes their
    // video ports are the ones in this line will read a forwarding rule they no longer need as the
    // reason a session has no video.
    if let Some(range) = &config.stale_video_ports {
        warn!(
            peeringd_video_ports = %range,
            peeringd_video_bind = %config.video_bind,
            "PEERINGD_VIDEO_PORTS is ignored: sessions no longer have video ports of their own, so there is no range to allocate from. Put the port you forward in PEERINGD_VIDEO_BIND, and in PEERINGD_PUBLIC_VIDEO_PORT if clients reach it on a different one; this line can be deleted from the environment file"
        );
    }

    tokio::spawn(tcp_relay::serve(control, Arc::clone(&registry), Arc::clone(&quota)));

    // Abandoned sessions are the normal residue of clients that crash or walk away, so this runs
    // forever rather than as a one-off. This is also what retires the video routes of a session
    // whose control connection died, so letting sessions accumulate would leak entries in a table
    // that lasts as long as the process, not just memory.
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

    info!(
        control = %config.control_addr,
        signal = %config.signal_addr,
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
        // The forwarded port unless one was named, read off the socket that was actually bound so
        // that a relay configured with `PEERINGD_VIDEO_BIND=0.0.0.0:0` still tells its clients
        // somewhere they can reach.
        video_port: config.public_video_port.unwrap_or(video.port()),
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
