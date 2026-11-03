//! A runtime over the stand-in adapters, for tests of the state that need no phone.

use std::sync::{Arc, Mutex, PoisonError};

use super::services::platform_services;
use super::shared::SessionSlot;
use super::outbound::outbound;
use super::{HostProfile, HostRuntime, SystemClock};
use peering_core::fakes::secret_store::InMemorySecretStore;
use peering_core::video::lane::VideoLane;
use peering_wire::handshake::ClientCapabilities;

/// On Windows building the adapters creates the install's entropy file on the first call, and two tests doing that at once make one of them fail to save it.
static BUILDING_ADAPTERS: Mutex<()> = Mutex::new(());

pub(super) fn runtime() -> HostRuntime {
    let mut services = {
        let _one_at_a_time = BUILDING_ADAPTERS.lock().unwrap_or_else(PoisonError::into_inner);
        platform_services(String::new()).expect("the stand-in adapters build")
    };
    // On Windows the adapters are the real ones, whose secret store is a file every test shares: a token one test registers would be found by the next.
    services.secrets = Arc::new(InMemorySecretStore::default());
    let profile = HostProfile {
        host_id: "host".to_owned(),
        host_name: "PC".to_owned(),
        identity_public_key: Vec::new(),
        mac_addresses: Vec::new(),
        clock: Arc::new(SystemClock::new()),
    };
    HostRuntime::new(profile, services).expect("the runtime builds over stand-ins")
}

/// A session for `client_id` whose queues nobody reads.
pub(super) fn slot(client_id: &str) -> SessionSlot {
    let (sender, _receiver) = outbound();
    SessionSlot {
        client_id: client_id.to_owned(),
        peer_key: None,
        outbound: sender,
        video_outbound: None,
        datagram_outbound: None,
        lane: VideoLane::new([0; 16]),
        background: false,
        client_flags: ClientCapabilities::default(),
        audio: Default::default(),
    }
}
