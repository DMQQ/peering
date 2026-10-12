//! DNS-SD advertisement of the host on `_remotedesktop._tcp`. The advertisement is withdrawn while a client is
//! connected and returns when the last client leaves, as the Mac host does.

mod registry;

use thiserror::Error;

pub use registry::MdnsRegistry;

pub const SERVICE_TYPE: &str = "_remotedesktop._tcp.local.";
pub const ADVERTISED_VERSION: &str = "20";

const MAX_INSTANCE_BYTES: usize = 63;
const FALLBACK_INSTANCE_NAME: &str = "Peering";

#[derive(Debug, Error)]
pub enum MdnsError {
    #[error("the mDNS registry failed: {0}")]
    Registry(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServiceAdvert {
    pub instance_name: String,
    pub host_name: String,
    pub port: u16,
    pub txt: Vec<(String, String)>,
}

impl ServiceAdvert {
    pub fn new(device_id: &str, display_name: &str, port: u16) -> Self {
        Self {
            instance_name: service_instance_name(display_name),
            host_name: format!("{}.local.", device_id.to_ascii_lowercase()),
            port,
            txt: txt_records(device_id, display_name, ADVERTISED_VERSION),
        }
    }
}

pub fn txt_records(device_id: &str, name: &str, version: &str) -> Vec<(String, String)> {
    vec![
        ("id".to_owned(), device_id.to_owned()),
        ("name".to_owned(), name.to_owned()),
        ("v".to_owned(), version.to_owned()),
    ]
}

/// Control characters and the DNS-SD separators are replaced by spaces, then the name is cut to 63 bytes on a character boundary.
pub fn service_instance_name(name: &str) -> String {
    let cleaned: String = name
        .trim()
        .chars()
        .map(|character| match character {
            '.' | '\\' => ' ',
            character if character.is_control() => ' ',
            character => character,
        })
        .collect();
    let truncated = truncate_to_bytes(cleaned.trim(), MAX_INSTANCE_BYTES);
    if truncated.is_empty() {
        FALLBACK_INSTANCE_NAME.to_owned()
    } else {
        truncated.to_owned()
    }
}

fn truncate_to_bytes(text: &str, limit: usize) -> &str {
    let mut end = text.len().min(limit);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

/// The registration side of the advertisement, so the withdrawal rule can be tested without a network.
pub trait ServiceRegistry {
    /// Returns the full name the registry will use to withdraw the service.
    fn register(&mut self, advert: &ServiceAdvert) -> Result<String, MdnsError>;
    fn unregister(&mut self, fullname: &str) -> Result<(), MdnsError>;
}

pub struct Advertiser<R: ServiceRegistry> {
    registry: R,
    advert: ServiceAdvert,
    registered_as: Option<String>,
}

impl<R: ServiceRegistry> Advertiser<R> {
    pub fn start(mut registry: R, advert: ServiceAdvert) -> Result<Self, MdnsError> {
        let registered_as = Some(registry.register(&advert)?);
        Ok(Self {
            registry,
            advert,
            registered_as,
        })
    }

    pub fn is_advertising(&self) -> bool {
        self.registered_as.is_some()
    }

    /// Withdraws the advertisement while any client is connected and re-advertises when none is.
    pub fn set_connected_clients(&mut self, count: usize) -> Result<(), MdnsError> {
        if count == 0 {
            if self.registered_as.is_none() {
                self.registered_as = Some(self.registry.register(&self.advert)?);
            }
        } else if let Some(fullname) = &self.registered_as {
            self.registry.unregister(fullname)?;
            self.registered_as = None;
        }
        Ok(())
    }
}
