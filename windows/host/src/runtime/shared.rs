//! The state the connections share. It is locked only for short synchronous steps and never across an await.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use peering_agent::manager::ClientAgents;
use peering_core::catalogue::{CatalogueService, SessionCatalogue};
use peering_core::files::browse::FileBrowser;
use peering_core::notice::NoticeTracker;
use peering_core::pairing::PairingService;
use peering_core::ports::input::InputSink;
use peering_core::session::deps::PinStore;
use peering_core::session::held_input::HoldGuard;
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
    /// What the phones have left pressed, so a phone that drops silently does not leave a key down.
    pub hold: HoldGuard,
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
    /// What is wrong right now, by source, for the window to show. A source clears its own entry when it recovers.
    pub problems: BTreeMap<&'static str, String>,
    /// Why the host ended, once it has. Kept here so the published snapshot does not overwrite it.
    pub stopped: Option<String>,
}

impl HostState {
    pub fn set_problem(&mut self, source: &'static str, text: String) {
        self.problems.insert(source, text);
    }

    pub fn clear_problem(&mut self, source: &'static str) {
        self.problems.remove(source);
    }

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

    /// Lets go of keys and buttons held by phones that have all gone quiet.
    pub fn release_silent_input(&mut self, now: f64) {
        if !self.hold.has_held() {
            return;
        }
        let transform = self.active_transform();
        self.hold.release_if_silent(now, peering_core::session::held_input::HELD_INPUT_TTL_SECONDS, &transform, &mut self.input);
    }

    /// A queue that discarded picture data left its phone without a frame the next ones depend on. The encoder is shared, so
    /// one resync serves every phone.
    pub fn resync_if_video_was_dropped(&mut self) -> bool {
        let mut dropped = false;
        for slot in self.sessions.values() {
            dropped |= slot.outbound.take_dropped_stale();
            dropped |= slot.video_outbound.as_ref().is_some_and(FrameSender::take_dropped_stale);
            dropped |= slot.datagram_outbound.as_ref().is_some_and(Outbound::take_dropped_stale);
        }
        if dropped {
            self.video.request_resync();
        }
        dropped
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

#[cfg(test)]
mod tests {
    use peering_core::outbound::OutboundQueue;
    use peering_core::video::lane::VideoLane;
    use peering_wire::framing::{Frame, MessageKind};

    use super::super::outbound::outbound_with;
    use super::super::services::platform_services;
    use super::super::{HostProfile, HostRuntime, SystemClock};
    use super::*;

    fn runtime() -> HostRuntime {
        let services = platform_services(String::new()).expect("the stand-in adapters build");
        let clock = std::sync::Arc::new(SystemClock::new());
        let profile = HostProfile {
            host_id: "host".to_owned(),
            host_name: "PC".to_owned(),
            identity_public_key: Vec::new(),
            mac_addresses: Vec::new(),
            can_lock_screen: false,
            clock,
        };
        HostRuntime::new(profile, services).expect("the runtime builds over stand-ins")
    }

    #[test]
    fn a_session_that_lost_queued_video_gets_a_resync_once() {
        let runtime = runtime();
        let (sender, _receiver) = outbound_with(OutboundQueue::<Frame>::with_limits(25, 1000, 100));
        let mut state = runtime.shared.lock();
        state.sessions.insert(
            1,
            SessionSlot {
                client_id: "phone".to_owned(),
                peer_key: None,
                outbound: sender.clone(),
                video_outbound: None,
                datagram_outbound: None,
                lane: VideoLane::new([0; 16]),
                background: false,
            },
        );
        assert!(!state.resync_if_video_was_dropped(), "a healthy queue asks for nothing");
        for _ in 0..3 {
            sender.send(Frame::new(MessageKind::VideoFrame, vec![0; 10])).expect("video is dropped, not refused");
        }
        assert!(state.resync_if_video_was_dropped(), "dropped video asks for a keyframe");
        assert!(!state.resync_if_video_was_dropped(), "and only once");
    }
}
