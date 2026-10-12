//! How long a connection lives: the reaper tick, eviction by the host, attaching a video connection to its session, and
//! leaving the shared state in order when the connection ends.

use peering_core::session::liveness::Verdict;
use peering_core::session::slots::{client_has_other_session, newest_session_for_key};

use super::{Connection, Flow};

impl Connection {
    pub(in super::super) fn now(&self) -> f64 {
        self.profile.clock.now_seconds()
    }

    /// True once the host has removed this connection's session, by forgetting the device or stopping hosting.
    pub(super) fn evicted(&self) -> bool {
        let session = self.video_for_session.unwrap_or(self.session_id);
        (self.registered || self.video_for_session.is_some()) && !self.shared.lock().sessions.contains_key(&session)
    }

    pub(super) fn on_tick(&mut self) -> Flow {
        if self.evicted() {
            return Flow::Closed;
        }
        let now = self.now();
        let phase = self.session.state().phase();
        self.liveness.note_phase(phase, now);
        let verdict = self.liveness.verdict_for(now, phase, self.video_for_session.is_some());
        if verdict == Verdict::End || !self.shared.lock().hosting {
            return Flow::Closed;
        }
        Flow::Open
    }

    pub(super) fn attach_video(&mut self) -> Flow {
        let Some(key) = self.peer.public_key.clone() else {
            return Flow::Closed;
        };
        let mut guard = self.shared.lock();
        let candidates = guard.sessions.iter().map(|(id, slot)| (*id, slot.peer_key.as_deref()));
        let Some(session_id) = newest_session_for_key(candidates, &key) else {
            return Flow::Closed;
        };
        let Some(slot) = guard.sessions.get_mut(&session_id) else {
            return Flow::Closed;
        };
        slot.video_outbound = Some(self.outbound.clone());
        self.video_for_session = Some(session_id);
        guard.video.lock().request_resync();
        Flow::Open
    }

    pub(super) fn finish(&mut self) {
        let mut guard = self.shared.lock();
        let state = &mut *guard;
        if let Some(session_id) = self.video_for_session.take() {
            if let Some(slot) = state.sessions.get_mut(&session_id) {
                if slot.video_outbound.as_ref().is_some_and(|sender| sender.same_channel(&self.outbound)) {
                    slot.video_outbound = None;
                }
            }
        }
        if let Some(slot) = state.sessions.remove(&self.session_id) {
            let siblings = state.sessions.iter().map(|(id, other)| (*id, other.client_id.as_str()));
            let last_of_client = !client_has_other_session(siblings, &slot.client_id, self.session_id);
            // The ceiling goes first: once capture stops, the encoder no longer takes a new bitrate.
            state.refresh_bitrate_ceiling();
            if last_of_client {
                let mut video = state.video.lock();
                video.detach(&slot.client_id);
                video.stop_when_idle();
            }
            state.release_input_if_idle();
            if last_of_client {
                state.terminals.disconnect(&slot.client_id);
            }
        }
        state.pairing.forget_session(self.session_id);
        state.catalogues.forget(&self.session_id);
    }
}
