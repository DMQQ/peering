//! One control or video connection. Bytes are framed here, the core's session decides what each frame means, and the
//! actions it returns are applied here: sent, shown to the pairing service, or used to end the connection.

use std::sync::Arc;
use std::time::Duration;

use peering_core::pairing::ApprovalDecision;
use peering_core::session::deps::{HostDeps, Random};
use peering_core::session::handshake::{HostConfig, HostSession};
use peering_core::session::liveness::{counts_as_life, LivenessTracker};
use peering_wire::framing::{Frame, FrameDecoder, MessageKind};
use peering_wire::handshake::{ClientCapabilities, ClientHello};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::broadcast;
use tokio::task::spawn_local;
use tokio::time::interval;

mod actions;
mod lifecycle;
mod register;

use super::outbound::{outbound, FrameSender, OutboundReceiver};
use super::pre_auth::PreAuthPermit;
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
    pub(super) outbound: FrameSender,
    pub(super) session: HostSession,
    pub(super) session_id: u64,
    pub(super) liveness: LivenessTracker,
    /// What the client's hello declared, which decides the events it may be sent.
    pub(super) client_flags: ClientCapabilities,
    pub(super) video_for_session: Option<u64>,
    pub(super) registered: bool,
    /// Held until the connection is authorised or turns out to be a video connection.
    pub(super) pre_auth: Option<PreAuthPermit>,
}

/// Serves one connection until the peer leaves, the core closes it, or the framing breaks.
pub async fn serve<S>(shared: Shared, profile: Arc<HostProfile>, stream: S, peer: PeerInfo)
where
    S: AsyncRead + AsyncWrite + Unpin + 'static,
{
    serve_counted(shared, profile, stream, peer, None).await;
}

/// `serve` for a connection that holds a pre-authentication slot, which it gives back once it is authorised.
pub async fn serve_counted<S>(shared: Shared, profile: Arc<HostProfile>, stream: S, peer: PeerInfo, pre_auth: Option<PreAuthPermit>)
where
    S: AsyncRead + AsyncWrite + Unpin + 'static,
{
    let (mut reader, writer) = tokio::io::split(stream);
    let (outbound, frames) = outbound();
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
        client_flags: ClientCapabilities::default(),
        video_for_session: None,
        registered: false,
        pre_auth,
    };
    connection.run(&mut reader).await;
    connection.finish();
}

async fn write_frames<W: AsyncWrite + Unpin>(mut writer: W, mut frames: OutboundReceiver<Frame>) {
    while let Some(frame) = frames.recv().await {
        // A peer that has stopped reading blocks the write; the queue passing its high-water mark is what ends it.
        let bytes = frame.encode();
        let written = tokio::select! {
            written = writer.write_all(&bytes) => written.is_ok(),
            () = frames.overflowed() => false,
        };
        if !written {
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
            let flow = tokio::select! {
                read = reader.read(&mut chunk) => match read {
                    Ok(0) | Err(_) => Flow::Closed,
                    Ok(count) => self.on_bytes(&mut decoder, &chunk[..count]),
                },
                () = self.outbound.overflowed() => Flow::Closed,
                _ = ticks.tick() => self.on_tick(),
                decision = approvals.recv(), if approvals_open => match decision {
                    Ok(decision) => self.on_approval(decision),
                    Err(broadcast::error::RecvError::Lagged(_)) => Flow::Open,
                    Err(broadcast::error::RecvError::Closed) => {
                        approvals_open = false;
                        Flow::Open
                    }
                },
            };
            if flow == Flow::Closed {
                return;
            }
        }
    }

    /// Feeds bytes to the framer and handles each whole frame. A framing error means the byte stream is out of step, and
    /// nothing after it can be trusted.
    fn on_bytes(&mut self, decoder: &mut FrameDecoder, bytes: &[u8]) -> Flow {
        decoder.push(bytes);
        loop {
            match decoder.next_frame() {
                Ok(Some(frame)) => {
                    if self.on_frame(frame) == Flow::Closed {
                        return Flow::Closed;
                    }
                }
                Ok(None) => return Flow::Open,
                Err(_) => return Flow::Closed,
            }
        }
    }

    /// The Mac user's answer reaches every connection; only the session that asked acts on it.
    fn on_approval(&mut self, decision: ApprovalDecision) -> Flow {
        if decision.session != self.session_id {
            return Flow::Open;
        }
        let actions = self.session.resolve_approval(decision.approved);
        self.apply_all(actions)
    }

    fn on_frame(&mut self, frame: Frame) -> Flow {
        if self.evicted() {
            return Flow::Closed;
        }
        if counts_as_life(self.session.state().phase(), frame.kind) {
            self.liveness.heard(self.now());
        }
        if self.registered && self.video_for_session.is_none() {
            let now = self.now();
            self.shared.lock().hold.heard(self.session_id, now);
        }
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
            self.client_flags = hello.capabilities;
        }
    }
}
