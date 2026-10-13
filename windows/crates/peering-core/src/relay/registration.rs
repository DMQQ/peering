//! The host's registration with the relay: what to send, when to ping, and when to reconnect. No sockets here. The
//! caller opens a connection when told to, writes what it is handed, and reports messages and disconnects back.

use std::collections::VecDeque;

use peering_wire::relay_messages::{RelayClientMessage, RelayServerMessage, Token};
use peering_wire::relay_proof::{make_host_proof, ProofSigner};

use crate::ports::clock::Clock;

const PING_INTERVAL: f64 = 25.0;
/// A socket that has said nothing for this long is half open: after sleep or a network change the OS keeps it up while
/// nothing arrives. The relay answers every ping, so two missed pings is silence.
pub const FRAME_DEADLINE: f64 = 2.0 * PING_INTERVAL;
const RECONNECT_DELAYS: [f64; 5] = [1.0, 2.0, 5.0, 10.0, 30.0];
/// The wait is a random share of the ladder step (full jitter), but never shorter than this.
const MINIMUM_RECONNECT_DELAY: f64 = 0.25;
/// The ladder starts over only after a registration has held this long, so a relay that accepts and then drops the
/// host does not keep it at one second.
pub const STABLE_REGISTRATION: f64 = 60.0;
const PROOF_STALE: &str = "proofStale";
const MAXIMUM_PENDING: usize = 16;

/// Where a session's two connections go, as the relay describes them in `sessionReady`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelaySession {
    pub control_host: String,
    pub control_port: u16,
    pub video_host: String,
    pub video_port: u16,
    pub control_token: Token,
    pub video_token: Token,
}

/// A push notification waiting for the relay. Optional fields are left out of the message when `None`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayNotification {
    pub device_token: String,
    pub title: String,
    pub body: String,
    pub source: Option<String>,
    pub category: Option<String>,
    pub session_id: Option<String>,
    pub approval_id: Option<String>,
}

impl RelayNotification {
    fn into_message(self) -> RelayClientMessage {
        RelayClientMessage::NotifyDevice {
            device_token: self.device_token,
            title: self.title,
            body: self.body,
            source: self.source,
            category: self.category,
            session_id: self.session_id,
            approval_id: self.approval_id,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RegAction {
    /// Open a new connection to the relay signalling endpoint, then call `start`.
    Connect,
    /// Close the current connection; the registration has already decided what happens next.
    Close,
    Send(RelayClientMessage),
    DialSession(RelaySession),
}

#[derive(Debug, Clone, Copy)]
enum Link {
    Idle,
    Waiting { due: f64 },
    Connecting,
    /// `next_ping` is set once the relay has said `registered`, and is the time of the next ping.
    Open { next_ping: Option<f64>, last_frame: f64, registered_at: Option<f64> },
}

/// Why the relay would not take the registration, when that is something the person can fix.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelayFault {
    /// The relay refused the signed proof as too old or too new: this PC's clock is more than a few minutes off.
    ClockSkew,
}

pub struct RelayRegistration {
    device_id: String,
    name: String,
    protocol_version: u16,
    signer: Box<dyn ProofSigner>,
    link: Link,
    attempt: usize,
    pending: VecDeque<RelayNotification>,
    jitter: Box<dyn FnMut() -> f64>,
    fault: Option<RelayFault>,
}

impl RelayRegistration {
    pub fn new(device_id: String, name: String, protocol_version: u16, signer: Box<dyn ProofSigner>) -> Self {
        Self {
            device_id,
            name,
            protocol_version,
            signer,
            link: Link::Idle,
            attempt: 0,
            pending: VecDeque::new(),
            jitter: Box::new(|| 1.0),
            fault: None,
        }
    }

    /// Sets where the reconnect jitter comes from: a value in `0.0..=1.0` per call. The default is 1.0, the full ladder
    /// step, which is what a test wants; the host passes a random source so hosts do not retry in step.
    pub fn with_jitter(mut self, jitter: Box<dyn FnMut() -> f64>) -> Self {
        self.jitter = jitter;
        self
    }

    /// What the person should be told about the last refusal, if it is one they can fix.
    pub fn fault(&self) -> Option<RelayFault> {
        self.fault
    }

    /// Any frame from the relay, including ones the caller handles itself, proves the socket is alive.
    pub fn note_frame(&mut self, clock: &dyn Clock) {
        if let Link::Open { last_frame, .. } = &mut self.link {
            *last_frame = clock.now_seconds();
        }
    }

    pub fn is_registered(&self) -> bool {
        matches!(self.link, Link::Open { next_ping: Some(_), .. })
    }

    /// Called once a connection is open. Every attempt signs a fresh proof, because the relay only accepts a timestamp
    /// close to its own clock and a retry loop can run for as long as the Mac does.
    pub fn start(&mut self, clock: &dyn Clock) -> Vec<RegAction> {
        let proof = make_host_proof(self.signer.as_ref(), &self.device_id, clock.unix_seconds());
        self.link = Link::Open { next_ping: None, last_frame: clock.now_seconds(), registered_at: None };
        vec![RegAction::Send(RelayClientMessage::RegisterHost {
            device_id: self.device_id.clone(),
            name: self.name.clone(),
            protocol_version: self.protocol_version,
            public_key: Some(proof.public_key),
            proof: Some(proof.signature),
            proof_time: Some(proof.proof_time),
        })]
    }

    pub fn on_message(&mut self, message: RelayServerMessage, clock: &dyn Clock) -> Vec<RegAction> {
        if !matches!(self.link, Link::Open { .. }) {
            return Vec::new();
        }
        self.note_frame(clock);
        match message {
            RelayServerMessage::Registered { .. } => self.on_registered(clock),
            RelayServerMessage::SessionReady {
                control_host,
                control_port,
                video_host,
                video_port,
                control_token,
                video_token,
                remaining_seconds: _,
            } => vec![RegAction::DialSession(RelaySession {
                control_host,
                control_port,
                video_host,
                video_port,
                control_token,
                video_token,
            })],
            RelayServerMessage::Error { code, .. } => {
                if code == PROOF_STALE {
                    self.fault = Some(RelayFault::ClockSkew);
                }
                self.on_disconnect(clock);
                vec![RegAction::Close]
            }
            RelayServerMessage::Pong
            | RelayServerMessage::HostOffline { .. }
            | RelayServerMessage::HostPresence { .. }
            | RelayServerMessage::PeerAddress { .. }
            | RelayServerMessage::ActivityRefused { .. }
            | RelayServerMessage::Unknown => Vec::new(),
        }
    }

    /// The connection went away, for any reason. The next attempt waits a random share of 1, 2, 5, 10 and then 30
    /// seconds, and stays at 30 until a registration has held for a minute. Reporting the same loss twice counts once.
    pub fn on_disconnect(&mut self, clock: &dyn Clock) {
        let now = clock.now_seconds();
        match self.link {
            Link::Waiting { .. } => return,
            Link::Open { registered_at: Some(since), .. } if now - since >= STABLE_REGISTRATION => self.attempt = 0,
            Link::Idle | Link::Connecting | Link::Open { .. } => {}
        }
        let step = RECONNECT_DELAYS[self.attempt.min(RECONNECT_DELAYS.len() - 1)];
        let share = (self.jitter)().clamp(0.0, 1.0);
        self.attempt += 1;
        self.link = Link::Waiting { due: now + (step * share).max(MINIMUM_RECONNECT_DELAY) };
    }

    /// Time-driven work: a reconnect that is due, a ping that is due while registered, and closing a socket the relay
    /// has stopped answering.
    pub fn tick(&mut self, clock: &dyn Clock) -> Vec<RegAction> {
        let now = clock.now_seconds();
        match self.link {
            Link::Waiting { due } if now >= due => {
                self.link = Link::Connecting;
                vec![RegAction::Connect]
            }
            Link::Open { last_frame, .. } if now - last_frame >= FRAME_DEADLINE => {
                self.on_disconnect(clock);
                vec![RegAction::Close]
            }
            Link::Open { next_ping: Some(due), last_frame, registered_at } if now >= due => {
                self.link = Link::Open { next_ping: Some(now + PING_INTERVAL), last_frame, registered_at };
                vec![RegAction::Send(RelayClientMessage::Ping)]
            }
            Link::Idle | Link::Waiting { .. } | Link::Connecting | Link::Open { .. } => Vec::new(),
        }
    }

    /// Queues a notification. It is sent at once when registered, and held otherwise. The queue keeps the newest 16.
    pub fn notify_device(&mut self, notification: RelayNotification) -> Vec<RegAction> {
        self.pending.push_back(notification);
        self.trim_pending();
        if self.is_registered() {
            self.flush()
        } else {
            Vec::new()
        }
    }

    /// Puts back notifications the caller could not write, ahead of anything queued since, in their original order.
    pub fn requeue(&mut self, unsent: Vec<RelayNotification>) {
        for notification in unsent.into_iter().rev() {
            self.pending.push_front(notification);
        }
        self.trim_pending();
    }

    fn on_registered(&mut self, clock: &dyn Clock) -> Vec<RegAction> {
        if self.is_registered() {
            return Vec::new();
        }
        let now = clock.now_seconds();
        self.fault = None;
        self.link = Link::Open { next_ping: Some(now + PING_INTERVAL), last_frame: now, registered_at: Some(now) };
        self.flush()
    }

    fn flush(&mut self) -> Vec<RegAction> {
        self.pending
            .drain(..)
            .map(|notification| RegAction::Send(notification.into_message()))
            .collect()
    }

    fn trim_pending(&mut self) {
        while self.pending.len() > MAXIMUM_PENDING {
            self.pending.pop_front();
        }
    }
}

#[cfg(test)]
mod tests;
