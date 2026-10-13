//! Building the state the connections share from the platform adapters.

use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

use peering_agent::availability::{AgentAvailability, BinaryLocator};
use peering_agent::browse::AgentBrowser;
use peering_agent::manager::{ClientAgents, AGENT_ID};
use peering_core::catalogue::{CatalogueService, SessionCatalogue};
use peering_core::files::browse::FileBrowser;
use peering_core::notice::NoticeTracker;
use peering_core::pairing::PairingService;
use peering_core::ports::encoder::Encoder;
use peering_core::ports::input::InputSink;
use peering_core::ports::system::SystemActions;
use peering_core::files::vfs::FileSystem;
use peering_core::session::deps::PinStore;
use peering_core::terminal::manager::TerminalSessionManager;
use peering_core::video::coordinator::VideoCoordinator;

use super::agent::StdLauncher;
use super::agent_browse::DiskFolders;
use super::control::RelayStatus;
use super::notifications::WaitingNotifications;
use super::pins::SecretPins;
use super::problem_source::ProblemSource;
use super::services::{BoxedEncoder, BoxedInput, BoxedSystem, HostServices, RebuildVideo, SharedCapture, SharedFileSystem};
use super::shared::HostState;
use super::terminal;
use super::video_handle::VideoHandle;
use super::{HostProfile, RuntimeError};

/// The adapters, with the stores that could fail to open already opened.
struct Opened {
    host_id: String,
    now: f64,
    pins: Arc<dyn PinStore>,
    terminals: TerminalSessionManager,
    capture: SharedCapture,
    encoder: Box<dyn Encoder + Send>,
    rebuild_video: RebuildVideo,
    input: Box<dyn InputSink + Send>,
    system: Box<dyn SystemActions + Send>,
    files: Arc<dyn FileSystem + Send + Sync>,
    home_directory: String,
    agent_binaries: Box<dyn BinaryLocator>,
}

impl HostState {
    /// Builds the state from the adapters. A paired list that could not be read starts empty and is shown as a problem.
    pub(super) fn new(profile: &HostProfile, services: HostServices) -> Result<Self, RuntimeError> {
        let HostServices { capture, encoder, input, system, secrets, files, terminal, rebuild_video, home_directory, agent_binaries } = services;
        let terminals = terminal::manager(terminal, secrets.clone(), profile.clock.clone())?;
        let secret_pins = Arc::new(SecretPins::open(secrets)?);
        let pins_problem = secret_pins.load_problem();
        let opened = Opened {
            host_id: profile.host_id.clone(),
            now: profile.clock.now_seconds(),
            pins: secret_pins,
            terminals,
            capture: SharedCapture::new(capture),
            encoder,
            rebuild_video,
            input,
            system,
            files,
            home_directory,
            agent_binaries,
        };
        let mut state = Self::assemble(opened);
        if let Some(problem) = pins_problem {
            state.set_problem(ProblemSource::PairedDevices, problem);
        }
        Ok(state)
    }

    fn assemble(opened: Opened) -> Self {
        let Opened { host_id, now, pins, terminals, capture, encoder, rebuild_video, input, system, files, home_directory, agent_binaries } = opened;
        Self {
            pairing: PairingService::new(&host_id, pins.clone()),
            pins,
            catalogue: CatalogueService::new(),
            catalogues: SessionCatalogue::new(),
            video: VideoHandle::new(VideoCoordinator::new(capture.clone(), BoxedEncoder(encoder)), capture, rebuild_video),
            input: BoxedInput(input),
            hold: Default::default(),
            system: BoxedSystem(system),
            agent_browser: Arc::new(AgentBrowser::new(DiskFolders(files.clone()), home_directory.clone())),
            files: Arc::new(FileBrowser::new(SharedFileSystem(files), home_directory)),
            agents: ClientAgents::new(StdLauncher::default),
            agent_availability: agent_availability(agent_binaries, now),
            terminals,
            notifications: WaitingNotifications::default(),
            sessions: HashMap::new(),
            next_session: 0,
            catalog_checked_at: None,
            notices: NoticeTracker::default(),
            notice_checked_at: None,
            hosting: true,
            relay: RelayStatus::Off,
            problems: BTreeMap::new(),
            stopped: None,
        }
    }
}

/// The first look for the agent CLI happens at startup, so the first hello does not wait for a search through `PATH`.
fn agent_availability(locator: Box<dyn BinaryLocator>, now: f64) -> AgentAvailability {
    let mut availability = AgentAvailability::new(locator, AGENT_ID);
    availability.check(now);
    availability
}
