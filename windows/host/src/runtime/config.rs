//! What the host is started with.

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayConfig {
    pub url: String,
    pub device_id: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeConfig {
    pub port: u16,
    /// `None` keeps the host off the relay; LAN and direct clients still work.
    pub relay: Option<RelayConfig>,
}
