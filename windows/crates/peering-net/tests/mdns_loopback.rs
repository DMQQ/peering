use std::time::Duration;

use mdns_sd::{ServiceDaemon, ServiceEvent};
use peering_net::mdns::{Advertiser, MdnsRegistry, ServiceAdvert, SERVICE_TYPE};

/// Stops the browsing daemon however the test ends, so it does not outlive the test.
struct BrowserDaemon(ServiceDaemon);

impl Drop for BrowserDaemon {
    fn drop(&mut self) {
        let _ = self.0.shutdown();
    }
}

#[test]
fn the_advertised_service_is_browsable_on_the_loopback_network() {
    let registry = match MdnsRegistry::new() {
        Ok(registry) => registry,
        Err(error) => {
            eprintln!("skipped: mDNS daemon unavailable here: {error}");
            return;
        }
    };
    let advert = ServiceAdvert::new("0F6B2C1E-8D4A-4B7E-9C3D-1A2B3C4D5E6F", "Loopback Mac", 51599);
    let _advertiser = Advertiser::start(registry, advert).expect("registers");

    let browser = BrowserDaemon(ServiceDaemon::new().expect("browser daemon"));
    let receiver = browser.0.browse(SERVICE_TYPE).expect("browses");
    let found = loop {
        match receiver.recv_timeout(Duration::from_secs(10)) {
            Ok(ServiceEvent::ServiceResolved(info)) if info.get_port() == 51599 => break true,
            Ok(_) => continue,
            Err(_) => break false,
        }
    };
    assert!(found, "the advertised service was not resolved");
}
