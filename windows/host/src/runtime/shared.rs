//! The state the connections share. It is locked only for short synchronous steps and never across an await.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use peering_agent::manager::ClientAgents;
use peering_core::catalogue::{CatalogueService, SessionCatalogue};
use peering_core::files::browse::FileBrowser;
use peering_core::notice::NoticeTracker;
use peering_core::pairing::PairingService;
use peering_core::ports::input::InputSink;
use peering_core::session::deps::PinStore;
use peering_core::terminal::manager::TerminalSessionManager;
use peering_core::video::coordinator::VideoCoordinator;
use peering_core::video::lane::VideoLane;
use tokio::sync::broadcast;

use super::control::{ControlChannel, RelayStatus};
use super::agent::StdLauncher;
use super::agent_browse::FolderBrowser;
use super::notifications::WaitingNotifications;
use super::outbound::{FrameSender, Outbound};
use super::peer_address::PeerAddressRouter;
use super::services::{BoxedEncoder, BoxedInput, BoxedSystem, SharedCapture, SharedFileSystem};

/// One authorised control connection. `video_outbound` is set while a direct video connection for the same client is open.
/// `datagram_outbound` feeds the session's relayed UDP lane; it is set only for a session that has one.
pub struct SessionSlot {
    pub client_id: String,
    pub peer_key: Option<Vec<u8>>,
    pub outbound: FrameSender,
    pub video_outbound: Option<FrameSender>,
    pub datagram_outbound: Option<Outbound<Vec<u8>>>,
    pub lane: VideoLane,
    /// The phone reported it left the foreground, so nothing is sent to it until it returns.
    pub background: bool,
}

impl SessionSlot {
    /// True while the session's relayed lane task is running, so a key granted now has a lane to send on.
    pub fn has_relay_lane(&self) -> bool {
        self.datagram_outbound.as_ref().is_some_and(|sender| !sender.is_closed())
    }
}

pub struct HostState {
    pub pins: Arc<dyn PinStore>,
    pub pairing: PairingService,
    pub capture: SharedCapture,
    pub catalogue: CatalogueService,
    pub catalogues: SessionCatalogue<u64>,
    pub video: VideoCoordinator<SharedCapture, BoxedEncoder>,
    pub input: BoxedInput,
    pub system: BoxedSystem,
    /// Shared so a request runs on the blocking pool with the state lock released.
    pub files: Arc<FileBrowser<SharedFileSystem>>,
    pub agents: ClientAgents<StdLauncher>,
    pub agent_browser: Arc<FolderBrowser>,
    pub terminals: TerminalSessionManager,
    /// Push notifications for the relay to send once the host is registered with it, oldest first.
    pub notifications: WaitingNotifications,
    pub sessions: HashMap<u64, SessionSlot>,
    pub next_session: u64,
    pub catalog_checked_at: Option<f64>,
    pub notices: NoticeTracker,
    pub notice_checked_at: Option<f64>,
    pub hosting: bool,
    pub relay: RelayStatus,
}

impl HostState {
    /// Lifts the keys and buttons the remote held, once no session is left to hold them. A phone that reconnects before
    /// its old connection is reaped keeps the keys it is holding.
    pub fn release_input_if_idle(&mut self) {
        if self.sessions.is_empty() {
            self.input.release_all();
        }
    }

    /// Encoding runs only while some session is in the foreground.
    pub fn refresh_watched(&mut self) {
        let watched = self.sessions.values().any(|slot| !slot.background);
        self.video.set_watched(watched);
    }

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
    pub peer_addresses: Arc<Mutex<PeerAddressRouter>>,
}

impl Shared {
    pub fn lock(&self) -> MutexGuard<'_, HostState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub fn peer_addresses(&self) -> MutexGuard<'_, PeerAddressRouter> {
        self.peer_addresses.lock().unwrap_or_else(PoisonError::into_inner)
    }
}
