use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use tokio::net::TcpListener;
use tracing::{error, info};
use tracing_subscriber::EnvFilter;

use peeringd::config::Config;
use peeringd::limits::PeerLimiter;
use peeringd::session::Registry;
use peeringd::signalling::HostRegistry;
use peeringd::supervise::{self, Health, Supervisor};
use peeringd::{signalling, stats, tcp_relay, udp_relay, web};

mod startup;
use startup::{build_hosts, build_quota, build_settings, build_tls, log_plan_policy, log_video};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .init();

    let config = Config::from_env()?;
    let registry = Arc::new(Registry::new(config.max_sessions));
    let hosts = build_hosts(&config);
    let tls = build_tls(&config)?;
    let quota = build_quota(&config);
    let receipts = Arc::new(peeringd::storekit::StoreKitVerifier::apple(config.trust_claimed_plans));
    log_plan_policy(&config, &receipts);

    let control = TcpListener::bind(config.control_addr).await?;
    let signal = TcpListener::bind(config.signal_addr).await?;
    // Failing to bind is fatal: a relay without video hands out sessions whose video goes nowhere.
    let (video, video_forwarder) =
        udp_relay::bind_forwarder(config.video_bind, registry.routes(), config.session_ttl).await?;
    log_video(&config, video);

    let health = Arc::new(Health::default());
    let mut tasks = Supervisor::new(Arc::clone(&health));
    let limiter = Arc::new(PeerLimiter::new(config.ip_limits));
    spawn_core_tasks(&mut tasks, &config, &registry, &limiter, control, video_forwarder);
    info!(
        control = %config.control_addr,
        signal = %config.signal_addr,
        session_ttl_seconds = config.session_ttl.as_secs(),
        "peeringd ready"
    );

    // A missing site must not stop the relay: this binds only the health endpoint then.
    if let Some((listener, root)) = web::bind(config.web_addr, config.web_root.clone()).await {
        tasks.spawn("web", web::serve(listener, Arc::new(root), Arc::clone(&health)));
    }

    let settings = build_settings(&config, quota, receipts, limiter, video.port());
    let bindings = hosts.clone();
    tasks.spawn("signalling", signalling::serve(signal, Arc::clone(&registry), hosts, settings, tls));

    run_until_stopped(tasks, bindings).await
}

/// Every task runs for the life of the process, so one that ends takes the process down for
/// systemd to restart rather than leaving a relay that answers health checks with a listener missing.
async fn run_until_stopped(mut tasks: Supervisor, bindings: HostRegistry) -> Result<(), Box<dyn std::error::Error>> {
    let failure = tokio::select! {
        exit = tasks.next_exit() => {
            error!(task = exit.name, panicked = exit.panicked, "a relay task stopped; shutting down so it is restarted");
            Some(exit.name)
        }
        _ = supervise::shutdown_requested() => {
            info!("stopping");
            None
        }
    };

    stats::TALLY.shutting_down();
    stats::TALLY.take_summary().log();
    let _ = tokio::task::spawn_blocking(move || bindings.flush_bindings()).await;

    match failure {
        Some(name) => Err(format!("the {name} task stopped").into()),
        None => Ok(()),
    }
}

fn spawn_core_tasks(
    tasks: &mut Supervisor,
    config: &Config,
    registry: &Arc<Registry>,
    limiter: &Arc<PeerLimiter>,
    control: TcpListener,
    video_forwarder: impl Future<Output = ()> + Send + 'static,
) {
    tasks.spawn(
        "control",
        tcp_relay::serve_limited(control, Arc::clone(registry), config.control_idle, Arc::clone(limiter)),
    );
    tasks.spawn("video", video_forwarder);
    tasks.spawn("stats", stats::report_forever());

    // Abandoned sessions are normal residue, and sweeping is also what retires the video routes of
    // a session whose control connection died.
    let sweep_registry = Arc::clone(registry);
    let ttl = config.session_ttl;
    tasks.spawn("sweep", async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(30));
        loop {
            ticker.tick().await;
            let swept = sweep_registry.sweep(ttl).await;
            if swept > 0 {
                info!(swept, "swept abandoned sessions");
            }
        }
    });
}
