//! Registering an authorised control connection as a session: its slot, its video state, and the relayed UDP lane when the
//! session arrived through the relay.

use peering_core::notice::notice_frame;
use peering_core::video::lane::VideoLane;
use peering_wire::sealing::TOKEN_SIZE;
use tokio::task::spawn_local;

use super::super::outbound::outbound;
use super::super::ready::error_frame;
use super::super::relay_lane;
use super::super::shared::SessionSlot;
use super::super::VideoEndpoint;
use super::Connection;

impl Connection {
    pub(super) fn register(&mut self) {
        self.registered = true;
        self.pre_auth = None;
        let client_id = self.session.client_id().to_owned();
        let video_token = self.peer.video_token.unwrap_or([0u8; TOKEN_SIZE]);
        let relay_lane = self.relay_video().map(|(endpoint, token)| (endpoint, token, outbound::<Vec<u8>>()));
        let now = self.now();
        let (frames, capture_failure) = {
            let mut guard = self.shared.lock();
            let state = &mut *guard;
            state.sessions.insert(
                self.session_id,
                SessionSlot {
                    client_id: client_id.clone(),
                    peer_key: self.peer.public_key.clone(),
                    outbound: self.outbound.clone(),
                    video_outbound: None,
                    datagram_outbound: relay_lane.as_ref().map(|(_, _, (sender, _))| sender.clone()),
                    lane: VideoLane::new(video_token),
                    background: false,
                },
            );
            let mut video = state.video.lock();
            video.attach(&client_id);
            let capture_failure = video.ensure_capturing(now).err().map(|error| error.to_string());
            drop(video);
            let mut frames = state.catalogue_frames_for(self.session_id);
            frames.extend(state.notices.standing().map(notice_frame));
            (frames, capture_failure)
        };
        if let Some((endpoint, token, (_, outbound))) = relay_lane {
            spawn_local(relay_lane::run(
                self.shared.clone(),
                self.profile.clone(),
                self.session_id,
                endpoint,
                token,
                outbound,
            ));
        }
        if let Some(failure) = capture_failure {
            self.send(error_frame("sourceUnavailable", &failure));
        }
        for frame in frames {
            self.send(frame);
        }
    }

    /// The relayed lane's endpoint and token, for a session that arrived through the relay with both.
    fn relay_video(&self) -> Option<(VideoEndpoint, [u8; TOKEN_SIZE])> {
        match (self.peer.via_relay, self.peer.video_endpoint.clone(), self.peer.video_token) {
            (true, Some(endpoint), Some(token)) => Some((endpoint, token)),
            _ => None,
        }
    }
}
