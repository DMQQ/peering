//! How the window and the tray see the host: a snapshot the runtime publishes about once a second, and the commands
//! they send back. Both are plain data, so they cross from the runtime thread to the UI thread.

use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use peering_core::pairing::ApprovalDecision;
use peering_core::ports::input::InputSink;
use peering_core::session::slots::sessions_of_client;
use peering_wire::handshake::ErrorPayload;
use peering_wire::pairing_payload;

use super::shared::HostState;

const PUBLISH_INTERVAL_SECONDS: f64 = 1.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RelayStatus {
    #[default]
    Off,
    Connecting,
    Registered,
    Retrying,
    /// The relay refuses this PC because its clock is off by more than the relay accepts.
    ClockSkew,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OfferView {
    pub code: String,
    pub client_name: String,
    pub via_relay: bool,
    /// The QR content that carries the code and the secret for the phone to scan.
    pub code_link: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApprovalView {
    pub id: u64,
    pub client_name: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceView {
    pub id: String,
    pub name: String,
    pub last_seen_unix: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HostSnapshot {
    pub hosting: bool,
    pub relay: RelayStatus,
    pub connected_clients: usize,
    /// The QR content that identifies this host's device id.
    pub host_link: String,
    pub offer: Option<OfferView>,
    pub approvals: Vec<ApprovalView>,
    pub devices: Vec<DeviceView>,
    /// The frame rate the encoder runs at, as the window's choice shows it.
    pub frame_rate: u32,
    /// Why the runtime ended, once it has. The tray shows it instead of a healthy-looking status.
    pub stopped: Option<String>,
    /// What is wrong while the host keeps running (capture recovering, a paired list that could not be read, a clock
    /// that is off). Each is a sentence for the window.
    pub problems: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RuntimeCommand {
    SetHosting(bool),
    Approve(u64),
    Decline(u64),
    Forget(String),
    SetFrameRate(u32),
}

/// The UI's end of the channel. Clone it freely; it can be used from any thread.
#[derive(Clone)]
pub struct HostHandle {
    published: Arc<Mutex<HostSnapshot>>,
    commands: Sender<RuntimeCommand>,
}

impl HostHandle {
    pub(super) fn new(published: Arc<Mutex<HostSnapshot>>, commands: Sender<RuntimeCommand>) -> Self {
        Self { published, commands }
    }

    pub fn snapshot(&self) -> HostSnapshot {
        self.published.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// Records that the runtime ended, so the window says why instead of showing its last healthy snapshot.
    pub fn report_stopped(&self, reason: String) {
        let mut published = self.published.lock().unwrap_or_else(PoisonError::into_inner);
        published.hosting = false;
        published.connected_clients = 0;
        published.stopped = Some(reason);
    }

    /// False once the runtime has stopped and no longer reads commands.
    pub fn send(&self, command: RuntimeCommand) -> bool {
        self.commands.send(command).is_ok()
    }
}

/// The runtime's end: commands in, the published snapshot out.
pub(super) struct ControlChannel {
    pub(super) published: Arc<Mutex<HostSnapshot>>,
    pub(super) commands: Receiver<RuntimeCommand>,
    pub(super) last_publish: Option<f64>,
}

impl HostState {
    /// The snapshot as the UI shows it. `host_id` is this host's device id.
    pub fn snapshot(&self, host_id: &str) -> HostSnapshot {
        HostSnapshot {
            hosting: self.hosting,
            relay: self.relay,
            connected_clients: self.sessions.len(),
            host_link: pairing_payload::host_link(host_id),
            offer: self.pairing.offer().map(|offer| OfferView {
                code: offer.code.clone(),
                client_name: offer.client_name.clone(),
                via_relay: offer.via_relay,
                code_link: offer.code_link.clone(),
            }),
            approvals: self
                .pairing
                .pending_approvals()
                .iter()
                .map(|pending| ApprovalView { id: pending.id, client_name: pending.client_name.clone() })
                .collect(),
            devices: self
                .pairing
                .paired_devices()
                .into_iter()
                .map(|device| DeviceView { id: device.id, name: device.name, last_seen_unix: device.last_seen_unix })
                .collect(),
            frame_rate: self.video.frame_rate(),
            stopped: self.stopped.clone(),
            problems: self.problems.values().cloned().collect(),
        }
    }

    /// Ends every session of a client that was removed: a pin revoked under a live session would otherwise leave the
    /// phone its picture and its input. Each connection notices its slot is gone and closes.
    fn end_client_sessions(&mut self, client_id: &str) {
        let siblings = self.sessions.iter().map(|(id, slot)| (*id, slot.client_id.as_str()));
        for id in sessions_of_client(siblings, client_id) {
            self.sessions.remove(&id);
        }
        let mut video = self.video.lock();
        video.detach(client_id);
        video.stop_when_idle();
        drop(video);
        self.input.release_all();
        self.terminals.disconnect(client_id);
    }

    /// Stops the sessions when hosting is switched off. Each is told first, so the client does not reconnect; the frame
    /// is queued ahead of the close, and the writer sends what is queued before it shuts the stream.
    fn stop_sessions(&mut self) {
        for (_, slot) in self.sessions.drain() {
            let _queued = slot.outbound.send(ErrorPayload::host_stopped_frame());
            self.video.lock().detach(&slot.client_id);
        }
        self.video.lock().stop_when_idle();
        self.input.release_all();
    }
}

/// Takes the commands sent since the last pass. Taken on their own, so the control lock is never held with the state lock.
pub(super) fn take_commands(control: &mut ControlChannel) -> Vec<RuntimeCommand> {
    std::iter::from_fn(|| control.commands.try_recv().ok()).collect()
}

impl HostState {
    /// Applies taken commands. Approvals are returned, to be delivered to the waiting sessions after the lock is released.
    pub(super) fn apply_commands(&mut self, commands: Vec<RuntimeCommand>) -> Vec<ApprovalDecision> {
        let mut decisions = Vec::new();
        for command in commands {
            match command {
                RuntimeCommand::SetHosting(hosting) => {
                    self.hosting = hosting;
                    if !hosting {
                        self.stop_sessions();
                    }
                }
                RuntimeCommand::Approve(id) => decisions.extend(self.pairing.approve(id)),
                RuntimeCommand::Decline(id) => decisions.extend(self.pairing.decline(id)),
                RuntimeCommand::Forget(client_id) => {
                    self.pairing.revoke(&client_id);
                    self.end_client_sessions(&client_id);
                }
                RuntimeCommand::SetFrameRate(fps) => self.video.lock().set_frame_rate(fps),
            }
        }
        decisions
    }
}

/// Publishes the snapshot when the last one is older than the publish interval.
pub(super) fn publish_if_due(state: &HostState, host_id: &str, control: &mut ControlChannel, now: f64) {
    if control.last_publish.is_some_and(|published| now - published < PUBLISH_INTERVAL_SECONDS) {
        return;
    }
    control.last_publish = Some(now);
    *lock(&control.published) = state.snapshot(host_id);
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}
