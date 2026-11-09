use std::net::IpAddr;
use std::time::Duration;

use mdns_sd::{IfKind, ServiceDaemon, ServiceInfo};

use super::{MdnsError, ServiceAdvert, ServiceRegistry, SERVICE_TYPE};

pub struct MdnsRegistry {
    daemon: ServiceDaemon,
    registered: Vec<String>,
}

impl MdnsRegistry {
    /// `hidden` are addresses of adapters a client could not reach. IPv6 is never announced, because the host listens on
    /// IPv4 only and a client that resolves a link-local IPv6 address would time out dialling it.
    pub fn new(hidden: &[IpAddr]) -> Result<Self, MdnsError> {
        let registry_error = |error: mdns_sd::Error| MdnsError::Registry(error.to_string());
        let daemon = ServiceDaemon::new().map_err(registry_error)?;
        daemon.disable_interface(IfKind::IPv6).map_err(registry_error)?;
        for address in hidden {
            daemon.disable_interface(IfKind::Addr(*address)).map_err(registry_error)?;
        }
        Ok(Self {
            daemon,
            registered: Vec::new(),
        })
    }
}

impl ServiceRegistry for MdnsRegistry {
    fn register(&mut self, advert: &ServiceAdvert) -> Result<String, MdnsError> {
        let info = ServiceInfo::new(
            SERVICE_TYPE,
            &advert.instance_name,
            &advert.host_name,
            (),
            advert.port,
            advert.txt.as_slice(),
        )
        .map_err(|error| MdnsError::Registry(error.to_string()))?
        .enable_addr_auto();
        let fullname = info.get_fullname().to_owned();
        self.daemon
            .register(info)
            .map_err(|error| MdnsError::Registry(error.to_string()))?;
        self.registered.push(fullname.clone());
        Ok(fullname)
    }

    fn unregister(&mut self, fullname: &str) -> Result<(), MdnsError> {
        self.registered.retain(|registered| registered != fullname);
        self.daemon
            .unregister(fullname)
            .map(|_| ())
            .map_err(|error| MdnsError::Registry(error.to_string()))
    }
}

/// Dropping the registry withdraws what it still advertises and stops the daemon, so a stopped host or a finished
/// test leaves nothing on the network for other devices to find.
impl Drop for MdnsRegistry {
    fn drop(&mut self) {
        for fullname in self.registered.drain(..) {
            if let Ok(withdrawn) = self.daemon.unregister(&fullname) {
                // The goodbye must be on the wire before the daemon stops.
                let _ = withdrawn.recv_timeout(WITHDRAW_WAIT);
            }
        }
        let _ = self.daemon.shutdown();
    }
}

const WITHDRAW_WAIT: Duration = Duration::from_secs(2);
