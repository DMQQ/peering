//! The host's registration with the relay: what to send, when to ping, and when to reconnect. No sockets here. The
//! caller opens a connection when told to, writes what it is handed, and reports messages and disconnects back.

use std::collections::VecDeque;

use peering_wire::relay_messages::{RelayClientMessage, RelayServerMessage, Token};
use peering_wire::relay_proof::{make_host_proof, ProofSigner};

use crate::ports::clock::Clock;

const PING_INTERVAL: f64 = 25.0;
const RECONNECT_DELAYS: [f64; 5] = [1.0, 2.0, 5.0, 10.0, 30.0];
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
    Open { next_ping: Option<f64> },
}

pub struct RelayRegistration {
    device_id: String,
    name: String,
    protocol_version: u16,
    signer: Box<dyn ProofSigner>,
    link: Link,
    attempt: usize,
    pending: VecDeque<RelayNotification>,
}

impl RelayRegistration {
    pub fn new(device_id: String, name: String, protocol_version: u16, signer: Box<dyn ProofSigner>) -> Self {
        Self { device_id, name, protocol_version, signer, link: Link::Idle, attempt: 0, pending: VecDeque::new() }
    }

    pub fn is_registered(&self) -> bool {
        matches!(self.link, Link::Open { next_ping: Some(_) })
    }

    /// Called once a connection is open. Every attempt signs a fresh proof, because the relay only accepts a timestamp
    /// close to its own clock and a retry loop can run for as long as the Mac does.
    pub fn start(&mut self, clock: &dyn Clock) -> Vec<RegAction> {
        let proof = make_host_proof(self.signer.as_ref(), &self.device_id, clock.unix_seconds());
        self.link = Link::Open { next_ping: None };
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
            RelayServerMessage::Error { .. } => {
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

    /// The connection went away, for any reason. The next attempt waits 1, 2, 5, 10 and then 30 seconds, and stays at 30.
    pub fn on_disconnect(&mut self, clock: &dyn Clock) {
        let delay = RECONNECT_DELAYS[self.attempt.min(RECONNECT_DELAYS.len() - 1)];
        self.attempt += 1;
        self.link = Link::Waiting { due: clock.now_seconds() + delay };
    }

    /// Time-driven work: a reconnect that is due, or a ping that is due while registered.
    pub fn tick(&mut self, clock: &dyn Clock) -> Vec<RegAction> {
        let now = clock.now_seconds();
        match self.link {
            Link::Waiting { due } if now >= due => {
                self.link = Link::Connecting;
                vec![RegAction::Connect]
            }
            Link::Open { next_ping: Some(due) } if now >= due => {
                self.link = Link::Open { next_ping: Some(now + PING_INTERVAL) };
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
        self.attempt = 0;
        self.link = Link::Open { next_ping: Some(clock.now_seconds() + PING_INTERVAL) };
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
