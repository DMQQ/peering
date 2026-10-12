use mdns_sd::{ServiceDaemon, ServiceInfo};

use super::{MdnsError, ServiceAdvert, ServiceRegistry, SERVICE_TYPE};

pub struct MdnsRegistry {
    daemon: ServiceDaemon,
}

impl MdnsRegistry {
    pub fn new() -> Result<Self, MdnsError> {
        let daemon = ServiceDaemon::new().map_err(|error| MdnsError::Registry(error.to_string()))?;
        Ok(Self { daemon })
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
        Ok(fullname)
    }

    fn unregister(&mut self, fullname: &str) -> Result<(), MdnsError> {
        self.daemon
            .unregister(fullname)
            .map(|_| ())
            .map_err(|error| MdnsError::Registry(error.to_string()))
    }
}
