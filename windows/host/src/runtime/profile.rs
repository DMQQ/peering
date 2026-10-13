//! What the host says about itself, and what it knows about the peer on a connection.

use std::net::IpAddr;
use std::sync::Arc;

use peering_core::ports::clock::Clock;
use peering_net::identity::HostIdentity;

/// What the host says about itself in its hello, shared by every connection.
pub struct HostProfile {
    pub host_id: String,
    pub host_name: String,
    /// The 65 byte point of the identity key, as the certificate carries it.
    pub identity_public_key: Vec<u8>,
    /// Wake-on-LAN addresses for paired clients. `HostRuntime::new` fills them from the adapters when none are given.
    pub mac_addresses: Vec<String>,
    pub clock: Arc<dyn Clock>,
}

impl HostProfile {
    pub fn from_identity(identity: &HostIdentity, host_name: &str, clock: Arc<dyn Clock>) -> Self {
        Self {
            host_id: identity.device_id().to_owned(),
            host_name: host_name.to_owned(),
            identity_public_key: identity.public_key_bytes(),
            mac_addresses: Vec::new(),
            clock,
        }
    }
}

/// Who is on the other end of a connection, as the transport established it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PeerInfo {
    pub public_key: Option<Vec<u8>>,
    /// The address a direct connection came from. A relayed session has none, because the relay is what the host sees.
    pub address: Option<IpAddr>,
    pub via_relay: bool,
    /// The relay's video token for a relayed session; direct connections have none.
    pub video_token: Option<[u8; 16]>,
    /// Where the relay takes a relayed session's datagrams. Set with `video_token`.
    pub video_endpoint: Option<VideoEndpoint>,
}

/// The relay's UDP port for a relayed session, as `sessionReady` names it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VideoEndpoint {
    pub host: String,
    pub port: u16,
}
