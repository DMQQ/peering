//! The Windows host process. The tray and pairing window come in later tasks; for now the process serves clients.

use std::sync::Arc;

use peering_host::runtime::{
    platform_services, HostProfile, HostRuntime, RelayConfig, RuntimeConfig, RuntimeError, SystemClock, DEFAULT_PORT,
};
use peering_net::identity::HostIdentity;

const RELAY_URL: &str = "wss://getpeering.app/";
const FALLBACK_HOST_NAME: &str = "Windows PC";

fn main() -> Result<(), RuntimeError> {
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
    let config = RuntimeConfig { port: DEFAULT_PORT, relay: Some(relay) };
    HostRuntime::new(profile, services)?.run(config, identity)
}
