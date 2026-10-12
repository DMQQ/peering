//! The state the connections share. It is locked only for short synchronous steps and never across an await.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use peering_core::catalogue::{CatalogueService, SessionCatalogue};
use peering_core::files::browse::FileBrowser;
use peering_core::pairing::PairingService;
use peering_core::session::deps::PinStore;
use peering_core::video::coordinator::VideoCoordinator;
use peering_core::video::lane::VideoLane;
use peering_wire::framing::Frame;
use tokio::sync::{broadcast, mpsc};

use super::control::{ControlChannel, RelayStatus};
use super::services::{BoxedEncoder, BoxedInput, SharedCapture, SharedFileSystem};

/// One authorised control connection. `video_outbound` is set while a direct video connection for the same client is open.
pub struct SessionSlot {
    pub client_id: String,
    pub peer_key: Option<Vec<u8>>,
    pub outbound: mpsc::UnboundedSender<Frame>,
    pub video_outbound: Option<mpsc::UnboundedSender<Frame>>,
    pub lane: VideoLane,
}

pub struct HostState {
    pub pins: Arc<dyn PinStore>,
    pub pairing: PairingService,
    pub capture: SharedCapture,
    pub catalogue: CatalogueService,
    pub catalogues: SessionCatalogue<u64>,
    pub video: VideoCoordinator<SharedCapture, BoxedEncoder>,
    pub input: BoxedInput,
    pub files: FileBrowser<SharedFileSystem>,
    pub sessions: HashMap<u64, SessionSlot>,
    pub next_session: u64,
    pub catalog_checked_at: Option<f64>,
    pub hosting: bool,
    pub relay: RelayStatus,
}

impl HostState {
    pub fn allocate_session(&mut self) -> u64 {
        self.next_session += 1;
        self.next_session
    }
}

/// Pairing approvals decided on the Mac side, delivered to the session that asked. Each session filters by its id.
pub type ApprovalSender = broadcast::Sender<peering_core::pairing::ApprovalDecision>;

#[derive(Clone)]
pub struct Shared {
    pub state: Arc<Mutex<HostState>>,
    pub approvals: ApprovalSender,
    pub control: Arc<Mutex<ControlChannel>>,
}

impl Shared {
    pub fn lock(&self) -> MutexGuard<'_, HostState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}
