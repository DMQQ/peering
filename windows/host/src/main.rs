//! The Windows host process. The runtime runs on its own thread; the tray and window run on the main thread, which
//! Windows requires for the tray.

use std::sync::mpsc;
use std::sync::Arc;
use std::thread;

use peering_host::runtime::{
    platform_services, HostHandle, HostProfile, HostRuntime, RelayConfig, RuntimeConfig, RuntimeError, SystemClock,
    DEFAULT_PORT,
};
use peering_net::identity::HostIdentity;

const RELAY_URL: &str = "wss://getpeering.app/";
const FALLBACK_HOST_NAME: &str = "Windows PC";

fn main() -> Result<(), RuntimeError> {
    let (ready, handles) = mpsc::channel();
    let host = thread::spawn(move || run_host(ready));
    match handles.recv() {
        Ok(handle) => show_ui(handle),
        // The host failed before it was ready, and its error is the one to report.
        Err(_) => host.join().unwrap_or_else(|_| Err(RuntimeError::Executor(std::io::Error::other("the host stopped")))),
    }
}

#[cfg(windows)]
fn show_ui(handle: HostHandle) -> Result<(), RuntimeError> {
    peering_host::ui::run(handle).map_err(|error| RuntimeError::Window(error.to_string()))
}

#[cfg(not(windows))]
fn show_ui(_handle: HostHandle) -> Result<(), RuntimeError> {
    // Off Windows there is no tray or window. The host keeps serving until the process is stopped.
    loop {
        thread::park();
    }
}

fn run_host(ready: mpsc::Sender<HostHandle>) -> Result<(), RuntimeError> {
    let home_directory = std::env::var("USERPROFILE").unwrap_or_else(|_| "C:\\".to_owned());
    let host_name = std::env::var("COMPUTERNAME").unwrap_or_else(|_| FALLBACK_HOST_NAME.to_owned());
    let services = platform_services(home_directory)?;
    let identity = HostIdentity::load(services.secrets.as_ref(), &host_name)
        .map_err(|error| RuntimeError::Identity(error.to_string()))?;
    let profile = HostProfile::from_identity(&identity, &host_name, Arc::new(SystemClock::new()));
    let relay = RelayConfig {
        url: RELAY_URL.to_owned(),
        device_id: identity.device_id().to_owned(),
        name: host_name,
    };
    let runtime = HostRuntime::new(profile, services)?;
    if ready.send(runtime.handle()).is_err() {
        return Ok(());
    }
    runtime.run(RuntimeConfig { port: DEFAULT_PORT, relay: Some(relay) }, identity)
}
