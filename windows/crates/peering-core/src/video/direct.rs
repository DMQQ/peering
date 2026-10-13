//! Host side of the direct path: knocks on the client's address until a probe from it authenticates, then keeps
//! a slow keepalive going toward the address that answered.

use std::net::SocketAddr;

/// Knocks this often while the first attempts last, then this often for the rest of the session.
const FAST_INTERVAL: f64 = 0.25;
const SLOW_INTERVAL: f64 = 5.0;
const FAST_ATTEMPTS: u32 = 12;
/// The relay is asked for the client's address on every attempt whose index is a multiple of this.
const REASK_EVERY: u32 = 12;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DirectPathState {
    NotTried,
    Probing,
    Open,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeAction {
    AskRelay,
    SendProbe(SocketAddr),
}

/// Pure schedule: the caller passes the monotonic time and sends whatever comes back.
#[derive(Debug)]
pub struct DirectPathKnocker {
    state: DirectPathState,
    peer: Option<SocketAddr>,
    attempts: u32,
    next_due: Option<f64>,
}

impl Default for DirectPathKnocker {
    fn default() -> Self {
        Self::new()
    }
}

impl DirectPathKnocker {
    pub fn new() -> Self {
        Self { state: DirectPathState::NotTried, peer: None, attempts: 0, next_due: None }
    }

    pub fn state(&self) -> DirectPathState {
        self.state
    }

    /// The address video goes to, but only once a probe from it has authenticated.
    pub fn video_destination(&self) -> Option<SocketAddr> {
        match self.state {
            DirectPathState::Open => self.peer,
            DirectPathState::NotTried | DirectPathState::Probing => None,
        }
    }

    /// The relay answered where the client is. An address that arrives after the path opened does not close it.
    pub fn on_peer_address(&mut self, address: SocketAddr) {
        self.peer = Some(address);
        if self.state == DirectPathState::NotTried {
            self.state = DirectPathState::Probing;
        }
    }

    /// A probe from `source` authenticated, so that source is where the client really is. The fast knocking ends,
    /// and the next probe goes out at the next call rather than after the rest of a fast gap.
    pub fn on_authenticated_datagram(&mut self, source: SocketAddr) {
        self.peer = Some(source);
        self.state = DirectPathState::Open;
        self.next_due = None;
    }

    /// The actions that are due at `now`, empty when the next attempt is still ahead.
    pub fn due_probes(&mut self, now: f64) -> Vec<ProbeAction> {
        if self.next_due.is_some_and(|due| now < due) {
            return Vec::new();
        }
        let mut actions = Vec::new();
        if self.attempts % REASK_EVERY == 0 {
            actions.push(ProbeAction::AskRelay);
        }
        if let Some(peer) = self.peer {
            actions.push(ProbeAction::SendProbe(peer));
        }
        self.attempts += 1;
        let fast = self.state != DirectPathState::Open && self.attempts < FAST_ATTEMPTS;
        let gap = if fast { FAST_INTERVAL } else { SLOW_INTERVAL };
        self.next_due = Some(now + gap);
        actions
    }
}

#[cfg(test)]
mod tests;
