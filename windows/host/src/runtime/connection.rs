//! One control or video connection. Bytes are framed here, the core's session decides what each frame means, and the
//! actions it returns are applied here: sent, shown to the pairing service, or used to end the connection.

use std::sync::Arc;
use std::time::Duration;

use peering_core::session::actions::SessionAction;
use peering_core::session::deps::{HostDeps, Random};
use peering_core::ports::input::InputSink;
use peering_core::session::handshake::{HostConfig, HostSession};
use peering_core::session::liveness::{LivenessTracker, Verdict};
use peering_wire::framing::{Frame, FrameDecoder, MessageKind};
use peering_wire::handshake::{ClientHello, ServerHello};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::{broadcast, mpsc};
use tokio::task::spawn_local;
use tokio::time::interval;

mod register;

use super::agent::StdLauncher;
use super::random::SystemRandomSource;
use super::shared::Shared;
use super::{HostProfile, PeerInfo};

const READ_CHUNK_BYTES: usize = 16 * 1024;
const TICK: Duration = Duration::from_secs(1);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Flow {
    Open,
    Closed,
}

pub(super) struct Connection {
    pub(super) shared: Shared,
    pub(super) profile: Arc<HostProfile>,
    pub(super) peer: PeerInfo,
    pub(super) outbound: mpsc::UnboundedSender<Frame>,
    pub(super) session: HostSession,
    pub(super) session_id: u64,
    pub(super) liveness: LivenessTracker,
    pub(super) supports_agent_chat: bool,
    pub(super) agent: Option<peering_agent::manager::AgentSessionManager<StdLauncher>>,
    pub(super) video_for_session: Option<u64>,
}

/// Serves one connection until the peer leaves, the core closes it, or the framing breaks.
pub async fn serve<S>(shared: Shared, profile: Arc<HostProfile>, stream: S, peer: PeerInfo)
where
    S: AsyncRead + AsyncWrite + Unpin + 'static,
{
    let (mut reader, writer) = tokio::io::split(stream);
    let (outbound, frames) = mpsc::unbounded_channel();
    spawn_local(write_frames(writer, frames));

    let session_id = shared.lock().allocate_session();
    let deps = HostDeps {
        random: Box::new(SystemRandomSource) as Box<dyn Random>,
        pins: shared.lock().pins.clone(),
        clock: profile.clock.clone(),
    };
    let config = HostConfig {
        host_id: profile.host_id.clone(),
        host_name: profile.host_name.clone(),
        identity_public_key: profile.identity_public_key.clone(),
        mac_addresses: profile.mac_addresses.clone(),
        peer_public_key: peer.public_key.clone(),
        arrived_through_relay: peer.via_relay,
    };
    let now = profile.clock.now_seconds();
    let mut connection = Connection {
        shared,
        profile,
        peer,
        outbound,
        session: HostSession::new(config, deps),
        session_id,
        liveness: LivenessTracker::started_at(now),
        supports_agent_chat: false,
        agent: None,
        video_for_session: None,
    };
    connection.run(&mut reader).await;
    connection.finish();
}

async fn write_frames<W: AsyncWrite + Unpin>(mut writer: W, mut frames: mpsc::UnboundedReceiver<Frame>) {
    while let Some(frame) = frames.recv().await {
        if writer.write_all(&frame.encode()).await.is_err() {
            break;
        }
    }
    let _shutdown = writer.shutdown().await;
}

impl Connection {
    async fn run<R: AsyncRead + Unpin>(&mut self, reader: &mut R) {
        let mut decoder = FrameDecoder::new();
        let mut chunk = vec![0u8; READ_CHUNK_BYTES];
        let mut ticks = interval(TICK);
        let mut approvals = self.shared.approvals.subscribe();
        let mut approvals_open = true;
        loop {
            tokio::select! {
                read = reader.read(&mut chunk) => {
                    let count = match read {
                        Ok(0) | Err(_) => return,
                        Ok(count) => count,
                    };
                    decoder.push(&chunk[..count]);
                    loop {
                        match decoder.next_frame() {
                            Ok(Some(frame)) => {
                                if self.on_frame(frame) == Flow::Closed {
                                    return;
                                }
                            }
                            Ok(None) => break,
                            // A framing error means the byte stream is out of step; nothing after it can be trusted.
                            Err(_) => return,
                        }
                    }
                }
                _ = ticks.tick() => {
                    if self.on_tick() == Flow::Closed {
                        return;
                    }
                }
                decision = approvals.recv(), if approvals_open => match decision {
                    Ok(decision) if decision.session == self.session_id => {
                        let actions = self.session.resolve_approval(decision.approved);
                        if self.apply_all(actions) == Flow::Closed {
                            return;
                        }
                    }
                    Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => approvals_open = false,
                },
            }
        }
    }

    pub(super) fn now(&self) -> f64 {
        self.profile.clock.now_seconds()
    }

    fn on_frame(&mut self, frame: Frame) -> Flow {
        self.liveness.heard(self.now());
        if self.video_for_session.is_some() {
            // A video connection only carries frames out; key and transport requests are answered on the control connection.
            return Flow::Open;
        }
        if frame.kind == MessageKind::ClientHello {
            self.note_hello(&frame);
        }
        let actions = self.session.on_frame(frame);
        self.apply_all(actions)
    }

    fn note_hello(&mut self, frame: &Frame) {
        if let Ok(hello) = serde_json::from_slice::<ClientHello>(&frame.payload) {
            self.supports_agent_chat = hello.capabilities.supports_agent_chat == Some(true);
        }
    }

    fn on_tick(&mut self) -> Flow {
        let now = self.now();
        if self.liveness.verdict(now, self.session.state().phase()) == Verdict::End || !self.shared.lock().hosting {
            return Flow::Closed;
        }
        let events = self.agent.as_mut().map(|manager| manager.poll()).unwrap_or_default();
        for event in events {
            self.send_event(&event);
        }
        Flow::Open
    }

    fn apply_all(&mut self, actions: Vec<SessionAction>) -> Flow {
        for action in actions {
            if self.apply(action) == Flow::Closed {
                return Flow::Closed;
            }
        }
        Flow::Open
    }

    fn apply(&mut self, action: SessionAction) -> Flow {
        match action {
            SessionAction::Send(frame) => self.send(self.decorate(frame)),
            SessionAction::Emit(event) => self.shared.lock().pairing.apply_event(&event),
            SessionAction::Authorized => self.register(),
            SessionAction::ForwardFrame(frame) => return self.on_ready(&frame),
            SessionAction::ForwardCommand(command) => self.dispatch_command(command),
            SessionAction::VideoConnection => return self.attach_video(),
            SessionAction::RequestApproval { client_name } => {
                self.shared.lock().pairing.request_approval(self.session_id, &client_name);
            }
            SessionAction::Close(_) => return Flow::Closed,
        }
        Flow::Open
    }

    pub(super) fn send(&self, frame: Frame) {
        // A writer that has stopped ends this connection on its next read, so a failed send needs no handling here.
        let _queued = self.outbound.send(frame);
    }

    pub(super) fn send_event<T: serde::Serialize>(&self, event: &T) {
        self.send(Frame::new(MessageKind::AgentEvent, serde_json::to_vec(event).expect("agent events always serialise")));
    }

    /// The host decorates its own hello with the services it runs, so the client sees what this build can do.
    fn decorate(&self, frame: Frame) -> Frame {
        if frame.kind != MessageKind::ServerHello {
            return frame;
        }
        let Ok(mut hello) = serde_json::from_slice::<ServerHello>(&frame.payload) else {
            return frame;
        };
        hello.capabilities.supports_agent_chat = Some(true);
        hello.capabilities.supports_agent_list = Some(true);
        hello.capabilities.supports_file_browser = Some(true);
        if self.profile.can_lock_screen {
            hello.capabilities.supports_lock_screen = Some(true);
        }
        hello.agent_chat_agents = Some(peering_agent::manager::agent_chat_agents());
        Frame::new(MessageKind::ServerHello, serde_json::to_vec(&hello).expect("a hello always serialises"))
    }

    fn attach_video(&mut self) -> Flow {
        let Some(key) = self.peer.public_key.clone() else {
            return Flow::Closed;
        };
        let mut guard = self.shared.lock();
        let Some((session_id, slot)) = guard.sessions.iter_mut().find(|(_, slot)| slot.peer_key.as_deref() == Some(key.as_slice()))
        else {
            return Flow::Closed;
        };
        slot.video_outbound = Some(self.outbound.clone());
        self.video_for_session = Some(*session_id);
        Flow::Open
    }

    fn finish(&mut self) {
        let mut guard = self.shared.lock();
        let state = &mut *guard;
        if let Some(session_id) = self.video_for_session.take() {
            if let Some(slot) = state.sessions.get_mut(&session_id) {
                slot.video_outbound = None;
            }
        }
        if let Some(slot) = state.sessions.remove(&self.session_id) {
            state.video.detach(&slot.client_id);
            state.input.release_all();
            if !state.sessions.values().any(|other| other.client_id == slot.client_id) {
                state.terminals.disconnect(&slot.client_id);
            }
        }
        state.pairing.forget_session(self.session_id);
        state.catalogues.forget(&self.session_id);
    }
}
