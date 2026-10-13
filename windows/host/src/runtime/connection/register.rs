//! Registering an authorised control connection as a session: its slot, its video state, and the relayed UDP lane when the
//! session arrived through the relay.

use peering_core::notice::notice_frame;
use peering_core::video::intent::VideoIntent;
use peering_core::video::lane::VideoLane;
use peering_wire::framing::Frame;
use peering_wire::sealing::TOKEN_SIZE;
use tokio::task::spawn_local;

use super::super::outbound::{outbound, Outbound};
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
        let datagrams = relay_lane.as_ref().map(|(_, _, (sender, _))| sender.clone());
        let (frames, capture_failure) = self.enter_session(&client_id, video_token, datagrams);
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
            self.report_source_failure(&failure);
        }
        for frame in frames {
            self.send(frame);
        }
    }

    /// Adds the session to the shared state and starts its picture. Returns the frames the phone is owed (the catalogue and
    /// any standing notice) and the reason capture could not start, if it could not.
    fn enter_session(
        &self,
        client_id: &str,
        video_token: [u8; TOKEN_SIZE],
        datagram_outbound: Option<Outbound<Vec<u8>>>,
    ) -> (Vec<Frame>, Option<String>) {
        let now = self.now();
        let mut guard = self.shared.lock();
        let state = &mut *guard;
        state.sessions.insert(
            self.session_id,
            SessionSlot {
                client_id: client_id.to_owned(),
                peer_key: self.peer.public_key.clone(),
                outbound: self.outbound.clone(),
                video_outbound: None,
                datagram_outbound,
                lane: VideoLane::new(video_token),
                background: false,
                client_flags: self.client_flags.clone(),
            },
        );
        state.refresh_keep_awake();
        state.video.request(VideoIntent::Attach(client_id.to_owned()));
        let capture_failure = state.video.apply(VideoIntent::EnsureCapturing, now).err().map(|error| error.to_string());
        let mut frames = state.catalogue_frames_for(self.session_id);
        frames.extend(state.notices.standing().map(notice_frame));
        (frames, capture_failure)
    }

    /// The relayed lane's endpoint and token, for a session that arrived through the relay with both.
    fn relay_video(&self) -> Option<(VideoEndpoint, [u8; TOKEN_SIZE])> {
        match (self.peer.via_relay, self.peer.video_endpoint.clone(), self.peer.video_token) {
            (true, Some(endpoint), Some(token)) => Some((endpoint, token)),
            _ => None,
        }
    }
}
