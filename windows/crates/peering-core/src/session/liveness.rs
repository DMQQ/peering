//! Silence limits for host sessions. Any inbound frame counts as proof of life; the limit depends on what the client has proven.

use peering_wire::framing::{Frame, MessageKind};

use super::state::HostPhase;

/// Silence limits from `apple/MacCastHost/Network/HostServer.swift` (reapSilentSessions).
pub const AUTHORISED_SILENCE_SECONDS: f64 = 60.0;
pub const UNAUTHENTICATED_SILENCE_SECONDS: f64 = 30.0;
pub const AWAITING_APPROVAL_SILENCE_SECONDS: f64 = 120.0;
pub const REAPER_INTERVAL_SECONDS: f64 = 5.0;
/// An authorised client the OS has frozen in the background says nothing, so it is given longer before it is reaped.
pub const BACKGROUND_SILENCE_SECONDS: f64 = 180.0;

pub fn silence_limit_seconds(phase: HostPhase) -> f64 {
    match phase {
        HostPhase::Authorized => AUTHORISED_SILENCE_SECONDS,
        HostPhase::Unauthenticated => UNAUTHENTICATED_SILENCE_SECONDS,
        HostPhase::AwaitingApproval => AWAITING_APPROVAL_SILENCE_SECONDS,
    }
}

/// Whether a frame proves the client is alive. Before the client is authorised only the frames that move the handshake
/// count, so a peer pinging every few seconds cannot hold an unauthenticated connection open. A client waiting on the
/// user's approval may still ping, since that wait is the user's to end.
pub fn counts_as_life(phase: HostPhase, kind: MessageKind) -> bool {
    match phase {
        HostPhase::Authorized => true,
        HostPhase::AwaitingApproval => matches!(kind, MessageKind::Ping | MessageKind::Pong),
        HostPhase::Unauthenticated => matches!(
            kind,
            MessageKind::ConnectionRole
                | MessageKind::ClientHello
                | MessageKind::PairCommit
                | MessageKind::PairReveal
                | MessageKind::PairConfirm
        ),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Keep,
    End,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LivenessTracker {
    last_heard: f64,
    background: bool,
}

impl LivenessTracker {
    pub fn started_at(now: f64) -> Self {
        Self { last_heard: now, background: false }
    }

    pub fn heard(&mut self, now: f64) {
        self.last_heard = now;
    }

    /// The client reported it left or returned to the foreground. Returning restores the normal limit.
    pub fn set_background(&mut self, background: bool) {
        self.background = background;
    }

    pub fn is_background(&self) -> bool {
        self.background
    }

    fn limit_seconds(&self, phase: HostPhase) -> f64 {
        let normal = silence_limit_seconds(phase);
        if self.background && phase == HostPhase::Authorized {
            normal.max(BACKGROUND_SILENCE_SECONDS)
        } else {
            normal
        }
    }

    /// A session is ended only once its silence is longer than the limit, so a frame exactly at the limit keeps it.
    pub fn verdict(&self, now: f64, phase: HostPhase) -> Verdict {
        if now - self.last_heard > self.limit_seconds(phase) {
            Verdict::End
        } else {
            Verdict::Keep
        }
    }
}

impl LivenessTracker {
    /// A video connection only carries frames out and the client never writes on it, so silence is not a sign it died.
    pub fn verdict_for(&self, now: f64, phase: HostPhase, video_connection: bool) -> Verdict {
        if video_connection {
            Verdict::Keep
        } else {
            self.verdict(now, phase)
        }
    }
}

/// The pong echoes the ping's payload, which is how a client matches it to the ping it sent.
pub fn pong_for(ping: &Frame) -> Frame {
    Frame::new(MessageKind::Pong, ping.payload.clone())
}

#[cfg(test)]
#[path = "liveness_tests.rs"]
mod tests;
