//! Announces the host on the local network over mDNS, so a client on the same Wi-Fi finds it without a code.

use peering_net::mdns::{Advertiser, MdnsRegistry, ServiceAdvert};

use super::RuntimeError;

/// The advertisement lives as long as the returned value.
pub fn start(device_id: &str, name: &str, port: u16) -> Result<Advertiser<MdnsRegistry>, RuntimeError> {
    #[cfg(windows)]
    let hidden = peering_platform::addresses::addresses_to_hide(&peering_platform::addresses::adapter_addresses());
    #[cfg(not(windows))]
    let hidden = Vec::new();
    let registry = MdnsRegistry::new(&hidden).map_err(|error| RuntimeError::Advertise(error.to_string()))?;
    Advertiser::start(registry, ServiceAdvert::new(device_id, name, port))
        .map_err(|error| RuntimeError::Advertise(error.to_string()))
}
