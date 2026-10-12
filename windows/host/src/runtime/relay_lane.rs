//! The relayed UDP lane of one session. It binds one unconnected socket to the relay, keeps that binding alive, sends sealed
//! video to the relay or straight to the client once a direct probe has authenticated, answers the client's pings, and knocks
//! for the direct path through the relay's `peerAddress`. Where a datagram goes is decided in `route.rs`.

mod route;

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use peering_core::video::direct::{DirectPathKnocker, ProbeAction};
use peering_core::video::lane::VideoLane;
use peering_wire::framing::{Frame, MessageKind};
use peering_wire::sealing::MAX_DATAGRAM_SIZE;
use tokio::net::{lookup_host, UdpSocket};
use tokio::time::interval;

use super::ask_queue::AskSender;
use super::outbound::OutboundReceiver;
use super::peer_address::answer_channel;
use super::shared::Shared;
use super::{HostProfile, VideoEndpoint};
use route::{arrival_path, route, Path};

const TICK: Duration = Duration::from_millis(50);

/// Runs until the session ends: its slot is gone, or the channel that carries its datagrams is closed.
pub async fn run(
    shared: Shared,
    profile: Arc<HostProfile>,
    session_id: u64,
    endpoint: VideoEndpoint,
    token: [u8; 16],
    mut outbound: OutboundReceiver<Vec<u8>>,
) {
    let Some(relay) = resolve(&endpoint).await else {
        return;
    };
    let Ok(socket) = bind_for(relay).await else {
        return;
    };
    let (answers_tx, mut answers) = answer_channel();
    let mut lane = RelayLane { shared, profile, session_id, socket, relay, token, knocker: DirectPathKnocker::new(), answers_tx };
    if !lane.on_tick().await {
        return;
    }
    let mut ticks = interval(TICK);
    let mut buffer = vec![0u8; MAX_DATAGRAM_SIZE + 1];
    loop {
        tokio::select! {
            received = lane.socket.recv_from(&mut buffer) => {
                // A failed receive drops that datagram only. On an unconnected socket Windows reports an earlier send's
                // ICMP error here, which says nothing about the datagrams still to come.
                if let Ok((count, source)) = received {
                    lane.on_arrival(&buffer[..count], source).await;
                }
            }
            _ = ticks.tick() => {
                if !lane.on_tick().await {
                    return;
                }
            }
            datagram = outbound.recv() => match datagram {
                Some(datagram) => lane.on_outbound(&datagram).await,
                None => return,
            },
            Some(address) = answers.recv() => lane.knocker.on_peer_address(address),
        }
    }
}

async fn resolve(endpoint: &VideoEndpoint) -> Option<SocketAddr> {
    lookup_host((endpoint.host.as_str(), endpoint.port)).await.ok()?.next()
}

async fn bind_for(relay: SocketAddr) -> std::io::Result<UdpSocket> {
    let local = if relay.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" };
    UdpSocket::bind(local).await
}

struct RelayLane {
    shared: Shared,
    profile: Arc<HostProfile>,
    session_id: u64,
    socket: UdpSocket,
    relay: SocketAddr,
    token: [u8; 16],
    knocker: DirectPathKnocker,
    answers_tx: AskSender<SocketAddr>,
}

impl RelayLane {
    /// Keeps the binding alive and sends the knocks that are due. False once the session has ended.
    async fn on_tick(&mut self) -> bool {
        let now = self.profile.clock.now_seconds();
        let Some(bind) = self.with_lane(|lane| lane.bind_if_due(now)) else {
            return false;
        };
        if let Some(bind) = bind {
            self.write(Path::Relay, &bind).await;
        }
        for action in self.knocker.due_probes(now) {
            match action {
                ProbeAction::AskRelay => {
                    let _asked = self.shared.peer_addresses().ask(self.token, self.answers_tx.clone());
                }
                ProbeAction::SendProbe(peer) => {
                    let probes = self.with_lane(|lane| lane.seal_datagrams(MessageKind::DirectProbe, &[])).unwrap_or_default();
                    for probe in probes {
                        self.write(Path::Direct(peer), &probe).await;
                    }
                }
            }
        }
        true
    }

    async fn on_outbound(&self, datagram: &[u8]) {
        let path = match self.knocker.video_destination() {
            Some(peer) => Path::Direct(peer),
            None => Path::Relay,
        };
        self.write(path, datagram).await;
    }

    async fn on_arrival(&mut self, datagram: &[u8], source: SocketAddr) {
        let opened = self.with_lane(|lane| lane.open_from_client(datagram).ok().flatten()).flatten();
        let Some(frame) = opened else {
            return;
        };
        let path = arrival_path(source, self.relay);
        if path != Path::Relay {
            self.knocker.on_authenticated_datagram(source);
        }
        if frame.kind == MessageKind::Ping {
            self.answer_ping(&frame, path).await;
        }
    }

    async fn answer_ping(&self, ping: &Frame, path: Path) {
        let pongs = self.with_lane(|lane| lane.seal_datagrams(MessageKind::Pong, &ping.payload)).unwrap_or_default();
        for pong in pongs {
            self.write(path, &pong).await;
        }
    }

    /// Writes one datagram. UDP is droppable and the next keyframe replaces a lost picture, so a failed send is not an error
    /// the lane can act on.
    async fn write(&self, path: Path, datagram: &[u8]) {
        if let Some((target, bytes)) = route(path, self.relay, datagram) {
            let _sent = self.socket.send_to(bytes, target).await;
        }
    }

    /// Runs `use_lane` on this session's lane under the state lock. None once the session has ended.
    fn with_lane<T>(&self, use_lane: impl FnOnce(&mut VideoLane) -> T) -> Option<T> {
        let mut state = self.shared.lock();
        state.sessions.get_mut(&self.session_id).map(|slot| use_lane(&mut slot.lane))
    }
}
