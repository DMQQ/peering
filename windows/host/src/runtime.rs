//! The host runtime: a current-thread tokio runtime with a `LocalSet`, serving the TCP listener, the relay registration,
//! the video pump and the mDNS advertisement over the core's synchronous state machines. Sessions are not `Send` (the
//! core holds boxed randomness and clocks), so every task is local and the shared state is only locked briefly.
//!
//! Module map: `listener` accepts, `connection` frames one connection and applies the core's actions, `ready` handles
//! authorised frames, `video` pumps capture and encode, `relay` keeps the relay registration, `agent` and `files` serve
//! the chat and file requests, `pins` stores paired devices, `services` holds the platform adapters.

mod advertise;
mod ask_queue;
mod agent;
mod agent_gate;
mod agent_browse;
mod agent_pump;
mod audio;
mod clipboard;
mod clock;
mod config;
mod connection;
mod control;
mod diagnostics;
mod disk;
mod error;
mod file_writer;
mod files;
mod focus_pump;
mod host_state;
mod hooks;
mod listener;
mod lock;
mod peer_address;
mod notifications;
mod outbound;
mod pins;
mod pointer_pump;
mod pre_auth;
mod problem_source;
mod profile;
mod random;
mod ready;
mod refusal;
mod relay;
mod relay_lane;
mod relay_switch;
mod serve;
mod services;
mod shared;
mod supervise;
mod terminal;
#[cfg(test)]
mod test_support;
mod video;
mod video_handle;
mod video_pass;
mod video_requests;

use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};

use peering_core::pairing::{ApprovalDecision, PairingOffer};
use peering_core::settings::HostSettings;
use peering_core::video::intent::VideoIntent;
use peering_wire::relay_messages::RelayClientMessage;
use tokio::sync::broadcast;

pub use ask_queue::AskReceiver;
pub use clock::SystemClock;
pub use config::{RelayConfig, RuntimeConfig};
pub use error::RuntimeError;
pub use profile::{HostProfile, PeerInfo, VideoEndpoint};
pub use control::{ApprovalView, DeviceView, HostHandle, HostSnapshot, OfferView, RelayStatus, RuntimeCommand};
pub use services::{platform_services, HostExtras, HostServices, RebuildVideo, TerminalServices};

use control::ControlChannel;
use peer_address::PeerAddressRouter;
use shared::{HostState, Shared};
pub use shared::SettingsSaver;

pub const DEFAULT_PORT: u16 = peering_core::settings::DEFAULT_PORT;
const APPROVAL_CHANNEL_DEPTH: usize = 16;

#[derive(Clone)]
pub struct HostRuntime {
    shared: Shared,
    profile: Arc<HostProfile>,
    commands: Sender<RuntimeCommand>,
}

impl HostRuntime {
    /// Builds the shared state from the adapters. Must be called on the thread that runs the `LocalSet` from `run`.
    pub fn new(profile: HostProfile, services: HostServices) -> Result<Self, RuntimeError> {
        let profile = HostProfile {
            mac_addresses: if profile.mac_addresses.is_empty() { services.system.hardware_addresses() } else { profile.mac_addresses },
            ..profile
        };
        let state = HostState::new(&profile, services)?;
        let (approvals, _unused_receiver) = broadcast::channel::<ApprovalDecision>(APPROVAL_CHANNEL_DEPTH);
        let (commands, command_inbox) = mpsc::channel();
        let control = ControlChannel {
            published: Arc::new(Mutex::new(HostSnapshot::default())),
            commands: command_inbox,
            last_publish: None,
        };
        Ok(Self {
            // The state holds boxed adapters that are not Send. Only the runtime's own thread locks it, so it is never shared.
            #[allow(clippy::arc_with_non_send_sync)]
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

    /// Uses `settings` as the person left them and `saver` to write the next change. The frame rate is applied now; the relay and
    /// the hooks follow the setting while the host runs.
    pub fn with_settings(self, settings: HostSettings, saver: SettingsSaver, problem: Option<String>) -> Self {
        {
            let mut state = self.shared.lock();
            state.video.request(VideoIntent::SetFrameRate(settings.frame_rate));
            state.settings = settings;
            state.settings_saver = saver;
            if let Some(problem) = problem {
                state.set_problem(problem_source::ProblemSource::Settings, problem);
            }
        }
        self
    }

    /// Starts the task that follows the Claude Code hooks setting: it puts the hooks into Claude Code when the setting is on and
    /// takes them out when it is off. `run` does this; tests call it directly.
    pub fn start_hooks(&self, files: crate::hooks::installer::HookFiles) {
        hooks::spawn_manager(self.shared.clone(), files);
    }

    /// The push notification at the head of the queue for the relay, if one is waiting.
    pub fn waiting_notification(&self) -> Option<RelayClientMessage> {
        self.shared.lock().notifications.next()
    }

    /// The UI's end of the host: the snapshot it reads and the commands it sends. Clone it freely.
    pub fn handle(&self) -> HostHandle {
        let published = lock::lock_ignoring_poison(&self.shared.control).published.clone();
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

    /// One look at the PC's pointer at `now`, delivered to the phones that asked to be told. The pointer task calls this.
    pub fn pump_pointer(&self, now: f64) {
        let outgoing = self.shared.lock().pump_pointer(now);
        video::deliver(outgoing);
    }

    /// One pass of the video pump at `now`, delivered to the connections. The timer calls this every frame interval.
    pub fn pump_video(&self, now: f64) -> Result<(), peering_core::video::coordinator::CoordinatorError> {
        let outgoing = video_pass::pump_video_inline(&self.shared, now)?;
        video::deliver(outgoing);
        Ok(())
    }

    /// Attaches a signalling socket to the relay's address answers, as the relay connection does when it opens. Returns the
    /// `requestPeerAddress` asks the video lanes make, for the caller to send on that socket.
    pub fn attach_signalling(&self) -> AskReceiver<RelayClientMessage> {
        let (outbound, asks) = peer_address::signalling_channel();
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
}
