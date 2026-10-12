//! The host runtime: a current-thread tokio runtime with a `LocalSet`, serving the TCP listener, the relay registration,
//! the video pump and the mDNS advertisement over the core's synchronous state machines. Sessions are not `Send` (the
//! core holds boxed randomness and clocks), so every task is local and the shared state is only locked briefly.
//!
//! Module map: `listener` accepts, `connection` frames one connection and applies the core's actions, `ready` handles
//! authorised frames, `video` pumps capture and encode, `relay` keeps the relay registration, `agent` and `files` serve
//! the chat and file requests, `pins` stores paired devices, `services` holds the platform adapters.

mod advertise;
mod agent;
mod agent_browse;
mod agent_pump;
mod clock;
mod config;
mod connection;
mod control;
mod diagnostics;
mod error;
mod files;
mod listener;
mod peer_address;
mod notifications;
mod outbound;
mod pins;
mod pre_auth;
mod random;
mod ready;
mod relay;
mod relay_lane;
mod services;
mod shared;
mod supervise;
mod terminal;
mod video;
mod video_requests;

use std::collections::HashMap;
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};

use peering_agent::browse::AgentBrowser;
use peering_agent::manager::ClientAgents;
use peering_core::catalogue::{CatalogueService, SessionCatalogue};
use peering_core::files::browse::FileBrowser;
use peering_core::ports::clock::Clock;
use peering_core::session::deps::PinStore;
use peering_core::pairing::{ApprovalDecision, PairingOffer, PairingService};
use peering_core::video::coordinator::VideoCoordinator;
use peering_net::identity::HostIdentity;
use peering_net::tls::HostTls;
use peering_wire::relay_messages::RelayClientMessage;
use tokio::net::TcpListener;
use tokio::sync::broadcast;
use tokio::task::{JoinHandle, LocalSet};

pub use clock::SystemClock;
pub use config::{RelayConfig, RuntimeConfig};
pub use error::RuntimeError;
pub use control::{ApprovalView, DeviceView, HostHandle, HostSnapshot, OfferView, RelayStatus, RuntimeCommand};
pub use services::{platform_services, HostServices, TerminalServices};

use agent::StdLauncher;
use agent_browse::DiskFolders;
use control::ControlChannel;
use notifications::WaitingNotifications;
use peer_address::PeerAddressRouter;
use pins::SecretPins;
use services::{BoxedEncoder, BoxedInput, BoxedSystem, SharedCapture, SharedFileSystem};
use shared::{HostState, Shared};

pub const DEFAULT_PORT: u16 = peering_core::settings::DEFAULT_PORT;
const APPROVAL_CHANNEL_DEPTH: usize = 16;

/// What the host says about itself in its hello, shared by every connection.
pub struct HostProfile {
    pub host_id: String,
    pub host_name: String,
    /// The 65 byte point of the identity key, as the certificate carries it.
    pub identity_public_key: Vec<u8>,
    /// Wake-on-LAN addresses for paired clients. Not collected yet, so the hello carries none.
    pub mac_addresses: Vec<String>,
    /// Whether the host can lock its workstation. `HostRuntime::new` sets this from the system adapter.
    pub can_lock_screen: bool,
    pub clock: Arc<dyn Clock>,
}

impl HostProfile {
    pub fn from_identity(identity: &HostIdentity, host_name: &str, clock: Arc<dyn Clock>) -> Self {
        Self {
            host_id: identity.device_id().to_owned(),
            host_name: host_name.to_owned(),
            identity_public_key: identity.public_key_bytes(),
            mac_addresses: Vec::new(),
            can_lock_screen: false,
            clock,
        }
    }
}

/// Who is on the other end of a connection, as the transport established it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PeerInfo {
    pub public_key: Option<Vec<u8>>,
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

#[derive(Clone)]
pub struct HostRuntime {
    shared: Shared,
    profile: Arc<HostProfile>,
    commands: Sender<RuntimeCommand>,
}

impl HostRuntime {
    /// Builds the shared state from the adapters. Must be called on the thread that runs the `LocalSet` from `run`.
    pub fn new(profile: HostProfile, services: HostServices) -> Result<Self, RuntimeError> {
        let HostServices { capture, encoder, input, system, secrets, files, terminal, home_directory } = services;
        let agent_browser = Arc::new(AgentBrowser::new(DiskFolders(files.clone()), home_directory.clone()));
        let profile = HostProfile { can_lock_screen: system.can_lock_workstation(), ..profile };
        let terminals = terminal::manager(terminal, secrets.clone(), profile.clock.clone())?;
        let pins: Arc<dyn PinStore> = Arc::new(SecretPins::open(secrets)?);
        let capture = SharedCapture::new(capture);
        let state = HostState {
            pins: pins.clone(),
            pairing: PairingService::new(&profile.host_id, pins),
            capture: capture.clone(),
            catalogue: CatalogueService::new(),
            catalogues: SessionCatalogue::new(),
            video: VideoCoordinator::new(capture, BoxedEncoder(encoder)),
            input: BoxedInput(input),
            system: BoxedSystem(system),
            files: Arc::new(FileBrowser::new(SharedFileSystem(files), home_directory)),
            agents: ClientAgents::new(StdLauncher::default),
            agent_browser,
            terminals,
            notifications: WaitingNotifications::default(),
            sessions: HashMap::new(),
            next_session: 0,
            catalog_checked_at: None,
            notices: peering_core::notice::NoticeTracker::default(),
            notice_checked_at: None,
            hosting: true,
            relay: RelayStatus::Off,
            problems: std::collections::BTreeMap::new(),
            stopped: None,
        };
        let (approvals, _unused_receiver) = broadcast::channel::<ApprovalDecision>(APPROVAL_CHANNEL_DEPTH);
        let (commands, command_inbox) = mpsc::channel();
        let control = ControlChannel {
            published: Arc::new(Mutex::new(HostSnapshot::default())),
            commands: command_inbox,
            last_publish: None,
        };
        Ok(Self {
            shared: Shared {
                state: Arc::new(Mutex::new(state)),
                approvals,
                control: Arc::new(Mutex::new(control)),
                peer_addresses: Arc::new(Mutex::new(PeerAddressRouter::default())),
            },
            // The profile holds a clock that is not Send. Only the runtime's own thread reads it, so it is never shared.
            #[allow(clippy::arc_with_non_send_sync)]
            profile: Arc::new(profile),
            commands,
        })
    }

    /// The UI's end of the host: the snapshot it reads and the commands it sends. Clone it freely.
    pub fn handle(&self) -> HostHandle {
        let published = self.shared.control.lock().unwrap_or_else(std::sync::PoisonError::into_inner).published.clone();
        HostHandle::new(published, self.commands.clone())
    }

    /// The snapshot as of now, for tests and for the first draw of the window.
    pub fn snapshot(&self) -> HostSnapshot {
        self.shared.lock().snapshot(&self.profile.host_id)
    }

    /// Serves one connection over any byte stream. The TCP listener calls this after TLS; tests call it over in-memory
    /// streams with a peer key they choose. Must run inside the `LocalSet`.
    pub async fn serve_stream<S>(&self, stream: S, peer: PeerInfo)
    where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + 'static,
    {
        connection::serve(self.shared.clone(), self.profile.clone(), stream, peer).await;
    }

    /// One pass of the terminal pump: reads the shells and delivers what they printed. The pump task calls this every tick.
    pub fn pump_terminals(&self) {
        let outgoing = self.shared.lock().pump_terminals();
        video::deliver(outgoing);
    }

    /// One pass of the video pump at `now`, delivered to the connections. The timer calls this every frame interval.
    pub fn pump_video(&self, now: f64) -> Result<(), peering_core::video::coordinator::CoordinatorError> {
        let outgoing = self.shared.lock().pump_video(now)?;
        video::deliver(outgoing);
        Ok(())
    }

    /// Attaches a signalling socket to the relay's address answers, as the relay connection does when it opens. Returns the
    /// `requestPeerAddress` asks the video lanes make, for the caller to send on that socket.
    pub fn attach_signalling(&self) -> tokio::sync::mpsc::UnboundedReceiver<RelayClientMessage> {
        let (outbound, asks) = tokio::sync::mpsc::unbounded_channel();
        self.shared.peer_addresses().attach(Some(outbound));
        asks
    }

    /// Passes on a `peerAddress` the relay sent on the attached signalling socket.
    pub fn answer_peer_address(&self, host: &str, port: u16) {
        if let Some(address) = peer_address::peer_socket_addr(host, port) {
            self.shared.peer_addresses().answer(address);
        }
    }

    /// The pairing offer the Mac shows: the six digit code, the QR secret and the client it is for, if one is waiting.
    pub fn pairing_offer(&self) -> Option<PairingOffer> {
        self.shared.lock().pairing.offer().cloned()
    }

    /// Approves a pairing that arrived without the QR secret. Returns false when no such request is pending.
    pub fn approve(&self, approval_id: u64) -> bool {
        self.decide(approval_id, true)
    }

    pub fn decline(&self, approval_id: u64) -> bool {
        self.decide(approval_id, false)
    }

    fn decide(&self, approval_id: u64, approved: bool) -> bool {
        let decision = {
            let mut state = self.shared.lock();
            if approved { state.pairing.approve(approval_id) } else { state.pairing.decline(approval_id) }
        };
        match decision {
            Some(decision) => {
                // No connection waiting on the decision means the client already left; nothing is lost.
                let _delivered = self.shared.approvals.send(decision);
                true
            }
            None => false,
        }
    }

    /// Starts the video pump and the command loop on the current local task set. `run` does this; tests call it directly.
    pub fn start_pump(&self) {
        self.spawn_pumps();
    }

    fn spawn_pumps(&self) -> PumpTasks {
        let meter = supervise::PassMeter::new();
        let published = self.shared.control.lock().unwrap_or_else(std::sync::PoisonError::into_inner).published.clone();
        supervise::spawn_hang_monitor(&meter, published);
        PumpTasks {
            video: video::spawn_pump(self.shared.clone(), self.profile.clone(), meter),
            agents: agent_pump::spawn_pump(self.shared.clone()),
        }
    }

    /// Runs the host until the process ends: binds the port, announces the host, and serves the relay and the pump.
    pub fn run(self, config: RuntimeConfig, identity: HostIdentity) -> Result<(), RuntimeError> {
        let executor = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(RuntimeError::Executor)?;
        let local = LocalSet::new();
        local.block_on(&executor, self.run_tasks(config, identity))
    }

    async fn run_tasks(self, config: RuntimeConfig, identity: HostIdentity) -> Result<(), RuntimeError> {
        let tls = Arc::new(HostTls::new(&identity).map_err(|error| RuntimeError::Tls(error.to_string()))?);
        let listener = TcpListener::bind(("0.0.0.0", config.port))
            .await
            .map_err(|source| RuntimeError::Bind { port: config.port, source })?;
        let _advertisement = advertise::start(identity.device_id(), &self.profile.host_name, config.port)?;
        let pumps = self.spawn_pumps();
        if let Some(relay_config) = config.relay {
            let relay_task = tokio::task::spawn_local(relay::run(
                self.shared.clone(),
                self.profile.clone(),
                tls.clone(),
                relay_config,
                Box::new(identity),
            ));
            watch_relay(self.shared.clone(), relay_task);
        }
        let serving = listener::serve_listener(self.shared.clone(), self.profile, tls, listener);
        tokio::select! {
            () = serving => Ok(()),
            stopped = watch_pumps(pumps) => Err(stopped),
        }
    }
}

struct PumpTasks {
    video: JoinHandle<()>,
    agents: JoinHandle<()>,
}

/// Waits for a pump that should never end. A pump that ended leaves the host serving a frozen picture, so it ends the
/// host with the reason, which the window shows.
async fn watch_pumps(pumps: PumpTasks) -> RuntimeError {
    tokio::select! {
        outcome = pumps.video => RuntimeError::TaskStopped { task: "video and command loop", reason: task_end_text(&outcome) },
        outcome = pumps.agents => RuntimeError::TaskStopped { task: "agent output loop", reason: task_end_text(&outcome) },
    }
}

/// A relay that ended only costs remote access, so it is shown as a problem and the host keeps serving the local network.
fn watch_relay(shared: Shared, task: JoinHandle<()>) {
    tokio::task::spawn_local(async move {
        let outcome = task.await;
        let mut state = shared.lock();
        state.relay = RelayStatus::Off;
        state.set_problem("relay", crate::strings::relay_task_stopped(&task_end_text(&outcome)));
    });
}

fn task_end_text(outcome: &Result<(), tokio::task::JoinError>) -> String {
    match outcome {
        Ok(()) => "it returned".to_owned(),
        Err(error) if error.is_panic() => "it panicked".to_owned(),
        Err(error) => error.to_string(),
    }
}
