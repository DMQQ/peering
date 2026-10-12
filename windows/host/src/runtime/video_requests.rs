//! The client's video requests on the control connection: the key for the relayed lane, and moving the picture between the
//! relayed lane and the control connection. Both are answered where the request arrives, so neither waits on the pump.

use peering_wire::framing::Frame;
use peering_wire::handshake::VideoTransportRequest;

use super::connection::{Connection, Flow};
use super::random::SystemRandomSource;

impl Connection {
    /// Grants this session's relayed lane its key. A session without a running lane is not granted one, so the picture stays
    /// on the control connection instead of going to a lane that cannot send it.
    pub(super) fn answer_video_key(&mut self) -> Flow {
        let grant = {
            let mut guard = self.shared.lock();
            guard
                .sessions
                .get_mut(&self.session_id)
                .filter(|slot| slot.has_relay_lane())
                .map(|slot| slot.lane.answer_key_request(&mut SystemRandomSource))
        };
        match grant {
            Some(Ok(frame)) => {
                self.send(frame);
                Flow::Open
            }
            // Without a grant the client waits for a key that never comes, so the connection ends and it reconnects.
            Some(Err(_)) => Flow::Closed,
            None => Flow::Open,
        }
    }

    /// Moves the picture to the control connection or back. A request the lane declines is not answered: the client repeats
    /// its request after a silence, which is how it learns the host is still refusing.
    pub(super) fn answer_video_transport(&mut self, frame: &Frame) -> Flow {
        let Ok(request) = serde_json::from_slice::<VideoTransportRequest>(&frame.payload) else {
            return Flow::Open;
        };
        let now = self.now();
        let mut guard = self.shared.lock();
        let state = &mut *guard;
        if let Some(slot) = state.sessions.get_mut(&self.session_id) {
            slot.lane.handle_transport_request(&request, now);
            let ceiling = slot.lane.bitrate_ceiling_kbps();
            state.video.set_bitrate_ceiling(ceiling);
        }
        Flow::Open
    }
}
