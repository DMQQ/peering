//! Terminal sessions in the host: the manager built from the platform's pseudo console, terminal requests answered on a
//! connection, and what the shells print delivered to the client that owns them.

use std::collections::VecDeque;
use std::sync::Arc;
use std::time::Duration;

use peering_core::files::browse::FileBrowser;
use peering_core::ports::clock::Clock;
use peering_core::ports::secret_store::{SecretStore, StoreError};
use peering_core::push_tokens::PushTokenStore;
use peering_core::terminal::manager::{Outcome, Poll, TerminalConfig, TerminalDeps, TerminalSessionManager};
use peering_core::terminal::push::{AgentLocator, PushAlert};
use peering_core::video::lane::Random;
use peering_agent::environment::find_binary;
use peering_wire::framing::{Frame, MessageKind};
use peering_wire::relay_messages::RelayClientMessage;
use peering_wire::terminal::{TerminalEvent, TerminalRequest};
use tokio::sync::mpsc;
use tokio::task::spawn_local;

use super::agent::{search_env, DiskExists};
use super::connection::{Connection, Flow};
use super::random::SystemRandomSource;
use super::services::{SharedFileSystem, TerminalServices};
use super::shared::HostState;
use super::video::Outgoing;

/// Alerts held for a relay that is not reachable. Older ones are dropped first: a prompt answered long ago is stale.
const MAXIMUM_WAITING_NOTIFICATIONS: usize = 20;

const BROWSE_TIMEOUT: Duration = Duration::from_secs(10);
const BROWSE_TIMED_OUT: &str = "This PC took too long to read that.";

pub(super) fn manager(
    services: TerminalServices,
    secrets: Arc<dyn SecretStore + Send + Sync>,
    clock: Arc<dyn Clock>,
) -> Result<TerminalSessionManager, StoreError> {
    let deps = TerminalDeps {
        spawner: services.spawner,
        tokens: Box::new(PushTokenStore::open(SharedSecrets(secrets))?),
        agents: Box::new(PathAgents),
        clock,
        new_id: Box::new(session_id_source()),
    };
    let config = TerminalConfig {
        shells: services.shells,
        directory: services.directory,
        environment: services.environment,
    };
    Ok(TerminalSessionManager::new(deps, config))
}

struct SharedSecrets(Arc<dyn SecretStore + Send + Sync>);

impl SecretStore for SharedSecrets {
    fn read(&self, name: &str) -> Result<Option<Vec<u8>>, StoreError> {
        self.0.read(name)
    }

    fn write(&self, name: &str, value: &[u8]) -> bool {
        self.0.write(name, value)
    }

    fn remove(&self, name: &str) -> bool {
        self.0.remove(name)
    }
}

/// The coding agents found on this PC's `PATH` and in the per-user install folders.
struct PathAgents;

impl AgentLocator for PathAgents {
    fn installed(&self, names: &[&str]) -> Vec<String> {
        let search = search_env();
        names.iter().filter(|name| find_binary(name, &search, &DiskExists).is_some()).map(|name| (*name).to_owned()).collect()
    }
}

/// Random version 4 UUIDs in uppercase. A failed random source falls back to a counter, which is still unique.
fn session_id_source() -> impl FnMut() -> String {
    let mut fallback = 0u64;
    move || {
        let mut bytes = [0u8; 16];
        if SystemRandomSource.fill(&mut bytes) {
            return uuid_v4(bytes);
        }
        fallback += 1;
        format!("00000000-0000-4000-8000-{fallback:012X}")
    }
}

fn uuid_v4(mut bytes: [u8; 16]) -> String {
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    let hex = hex::encode_upper(bytes);
    format!("{}-{}-{}-{}-{}", &hex[..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..])
}

fn event_frame(event: &TerminalEvent) -> Frame {
    Frame::new(MessageKind::TerminalEvent, serde_json::to_vec(event).expect("terminal events always serialise"))
}

impl Connection {
    /// Answers a terminal or file request from this client. A framing-valid request that does not decode ends the connection.
    pub(super) fn terminal_request(&mut self, frame: &Frame) -> Flow {
        let Ok(request) = serde_json::from_slice::<TerminalRequest>(&frame.payload) else {
            return Flow::Closed;
        };
        let client_id = self.session.client_id().to_owned();
        let (events, browser) = {
            let mut state = self.shared.lock();
            match state.terminals.handle(&client_id, &request) {
                Outcome::Events(events) => (events, None),
                Outcome::Browse => (Vec::new(), Some(state.files.clone())),
            }
        };
        for event in &events {
            self.send(event_frame(event));
        }
        if let Some(browser) = browser {
            answer_browse(browser, request, self.outbound.clone());
        }
        Flow::Open
    }
}

/// Runs a disk request off the runtime thread. A drive that never answers costs the client one failure, not every
/// session a frozen host.
fn answer_browse(browser: Arc<FileBrowser<SharedFileSystem>>, request: TerminalRequest, outbound: mpsc::UnboundedSender<Frame>) {
    spawn_local(async move {
        let asked = request.clone();
        let work = tokio::task::spawn_blocking(move || browser.answer(&request));
        let event = match tokio::time::timeout(BROWSE_TIMEOUT, work).await {
            Ok(Ok(event)) => event,
            Ok(Err(_)) | Err(_) => FileBrowser::<SharedFileSystem>::failure(&asked, BROWSE_TIMED_OUT),
        };
        if let Some(event) = event {
            // The connection may have closed meanwhile; there is then nobody to tell.
            let _queued = outbound.send(event_frame(&event));
        }
    });
}

impl HostState {
    /// Reads the shells. Output goes to the newest connection of the client that owns it; alerts for a client that is
    /// not connected wait for the relay.
    pub fn pump_terminals(&mut self) -> Vec<Outgoing> {
        let Poll { events, pushes } = self.terminals.poll();
        for alert in pushes {
            self.queue_notification(alert);
        }
        let mut outgoing = Vec::new();
        for item in events {
            let newest = self.sessions.iter().filter(|(_, slot)| slot.client_id == item.client_id).max_by_key(|(id, _)| **id);
            if let Some((_, slot)) = newest {
                outgoing.push(Outgoing { to: slot.outbound.clone(), frame: event_frame(&item.event) });
            }
        }
        outgoing
    }

    fn queue_notification(&mut self, alert: PushAlert) {
        hold(&mut self.notifications, notify_message(alert));
    }
}

fn notify_message(alert: PushAlert) -> RelayClientMessage {
    RelayClientMessage::NotifyDevice {
        device_token: alert.token,
        title: alert.title,
        body: alert.message,
        source: None,
        category: None,
        session_id: None,
        approval_id: None,
    }
}

fn hold(queue: &mut VecDeque<RelayClientMessage>, message: RelayClientMessage) {
    queue.push_back(message);
    while queue.len() > MAXIMUM_WAITING_NOTIFICATIONS {
        queue.pop_front();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_session_id_is_an_uppercase_version_4_uuid() {
        let id = uuid_v4([0xAB; 16]);
        assert_eq!(id, "ABABABAB-ABAB-4BAB-ABAB-ABABABABABAB");
        assert_eq!(uuid_v4([0; 16]), "00000000-0000-4000-8000-000000000000");
    }

    #[test]
    fn two_generated_ids_differ() {
        let mut next = session_id_source();
        assert_ne!(next(), next());
    }

    fn alert(number: usize) -> PushAlert {
        PushAlert { token: "ab".to_owned(), title: "Terminal needs you".to_owned(), message: format!("prompt {number}") }
    }

    #[test]
    fn an_alert_becomes_a_notify_device_message() {
        let RelayClientMessage::NotifyDevice { device_token, title, body, .. } = notify_message(alert(1)) else {
            panic!("a notify message");
        };
        assert_eq!((device_token.as_str(), title.as_str(), body.as_str()), ("ab", "Terminal needs you", "prompt 1"));
    }

    #[test]
    fn a_relay_that_stays_away_keeps_only_the_newest_alerts() {
        let mut queue = VecDeque::new();
        for number in 0..MAXIMUM_WAITING_NOTIFICATIONS + 5 {
            hold(&mut queue, notify_message(alert(number)));
        }
        assert_eq!(queue.len(), MAXIMUM_WAITING_NOTIFICATIONS);
        let Some(RelayClientMessage::NotifyDevice { body, .. }) = queue.front() else { panic!("one is waiting") };
        assert_eq!(body, "prompt 5");
    }
}
