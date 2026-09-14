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
use peeringd::session::Registry;
use peeringd::signalling::{HostRegistry, Settings};
use peeringd::{signalling, tcp_relay};

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
    let control = TcpListener::bind(config.control_addr).await?;
    let signal = TcpListener::bind(config.signal_addr).await?;

    tokio::spawn(tcp_relay::serve(control, Arc::clone(&registry)));

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

    info!(
        control = %config.control_addr,
        signal = %config.signal_addr,
        video_bind = %config.video_bind,
        session_ttl_seconds = config.session_ttl.as_secs(),
        "peeringd ready"
    );

    let settings = Settings {
        host: None,
        control_port: config.control_addr.port(),
        video_bind: config.video_bind,
        session_ttl: config.session_ttl,
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
