//! Brings Claude Code's permission requests and notifications to the phone while the setting is on. The loopback server and
//! the broker are `crate::hooks` and `peering_core::terminal::hooks`; this starts and stops them with the setting, carries a
//! hook from the server's threads to the runtime's, and turns what the broker wants to push into relay messages.

use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use peering_core::ports::clock::Clock;
use peering_core::terminal::hooks::broker::{Answer, HookBroker, HookPush, Phones, Reply};
use peering_core::terminal::hooks::event::HookEvent;
use peering_core::terminal::hooks::settings::PERMISSION_TIMEOUT_SECONDS;
use peering_wire::agent::AgentApprovalDecision;
use peering_wire::relay_messages::RelayClientMessage;
use ring::rand::{SecureRandom, SystemRandom};
use tokio::task::{spawn_local, JoinHandle};
use tokio::time::interval;

use super::problem_source::ProblemSource;
use super::shared::Shared;
use super::supervise::record_problem;
use super::SystemClock;
use crate::hooks::installer::HookFiles;
use crate::hooks::server::{HookServer, HookServerConfig};
use crate::strings;

const TICK: Duration = Duration::from_millis(250);
const TOKEN_BYTES: usize = 16;

type Incoming = (HookEvent, Reply);

/// The broker's view of the phones: a snapshot of their tokens it reads, and a box of pushes it fills. Both are filled and
/// emptied by the runtime thread, so the broker, which can be called from the server's threads, never reaches the host state.
#[derive(Default)]
struct Bridge {
    tokens: Mutex<Vec<String>>,
    pushes: Mutex<Vec<HookPush>>,
}

fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Phones for Bridge {
    fn tokens(&self) -> Vec<String> {
        locked(&self.tokens).clone()
    }

    fn push(&self, push: HookPush) {
        locked(&self.pushes).push(push);
    }
}

/// The hooks while they are on: the server that listens, and the broker its requests go to.
struct Running {
    broker: Arc<HookBroker>,
    bridge: Arc<Bridge>,
    inbox: Receiver<Incoming>,
    _server: HookServer,
}

impl Running {
    /// Hands the hooks that arrived to the broker, lets the unanswered expire, and returns the pushes to send.
    fn tick(&self, tokens: Vec<String>) -> Vec<RelayClientMessage> {
        *locked(&self.bridge.tokens) = tokens;
        while let Ok((event, reply)) = self.inbox.try_recv() {
            self.broker.handle(&event, reply);
        }
        self.broker.expire();
        std::mem::take(&mut *locked(&self.bridge.pushes)).into_iter().map(push_message).collect()
    }
}

/// A broker push as the relay message that reaches the phone. An approval carries the ids the phone answers with.
pub(super) fn push_message(push: HookPush) -> RelayClientMessage {
    let (category, session_id, approval_id) = match push.action {
        Some(action) => (Some(action.category.to_owned()), Some(action.session_id), Some(action.approval_id)),
        None => (None, None, None),
    };
    RelayClientMessage::NotifyDevice {
        device_token: push.token,
        title: push.title,
        body: push.body,
        source: None,
        category,
        session_id,
        approval_id,
    }
}

/// What a phone's answer to an approval means to the broker.
pub(super) fn answer_of(decision: &AgentApprovalDecision) -> Answer {
    match decision {
        AgentApprovalDecision::Allow {} => Answer::Allow,
        AgentApprovalDecision::Deny {} => Answer::Deny,
        AgentApprovalDecision::Choose { .. } => Answer::Choose,
    }
}

fn mint_token() -> Option<String> {
    let mut bytes = [0u8; TOKEN_BYTES];
    SystemRandom::new().fill(&mut bytes).ok()?;
    Some(hex::encode(bytes))
}

fn approval_id_source() -> Box<dyn Fn() -> String + Send + Sync> {
    Box::new(|| {
        let mut bytes = [0u8; 16];
        // A failed generator gives an id of zeros, which a held request would share with the next: the broker then answers
        // the newer and lets the older fall back to the terminal prompt.
        let _filled = SystemRandom::new().fill(&mut bytes);
        hex::encode_upper(bytes)
    })
}

async fn start(files: &HookFiles) -> Result<Running, String> {
    let token = mint_token().ok_or_else(|| strings::HOOKS_NO_RANDOM.to_owned())?;
    let (sender, inbox) = channel::<Incoming>();
    let sender = Mutex::new(sender);
    let handler: crate::hooks::server::Handler = Arc::new(move |event, reply| {
        let _queued = send_to_runtime(&sender, event, reply);
    });
    let config = HookServerConfig { token: token.clone(), reply_deadline: Duration::from_secs(PERMISSION_TIMEOUT_SECONDS) };
    let server = HookServer::start(0, config, handler).await.map_err(|error| strings::hooks_could_not_listen(&error.to_string()))?;
    files.install(server.port(), &token).map_err(|error| strings::hooks_could_not_install(&error.to_string()))?;
    let bridge = Arc::new(Bridge::default());
    let clock: Arc<dyn Clock + Send + Sync> = Arc::new(SystemClock::new());
    let broker = Arc::new(HookBroker::new(bridge.clone(), clock, approval_id_source()));
    Ok(Running { broker, bridge, inbox, _server: server })
}

/// A hook whose runtime has gone is answered with nothing, so Claude Code shows its own prompt.
fn send_to_runtime(sender: &Mutex<Sender<Incoming>>, event: HookEvent, reply: Reply) -> Result<(), ()> {
    locked(sender).send((event, reply)).map_err(|failed| {
        let (_event, reply) = failed.0;
        reply(None);
    })
}

/// Runs for the life of the host: starts the hooks when the setting turns on, takes them out again when it turns off, and
/// moves their traffic once a tick.
pub(super) fn spawn_manager(shared: Shared, files: HookFiles) -> JoinHandle<()> {
    spawn_local(async move {
        let mut ticks = interval(TICK);
        let mut running: Option<Running> = None;
        loop {
            ticks.tick().await;
            let wanted = shared.lock().settings.terminal_hooks;
            match (wanted, running.is_some()) {
                (true, false) => running = start_and_report(&shared, &files).await,
                (false, true) => running = stop_and_report(&shared, &files, running),
                _ => {}
            }
            if let Some(active) = &running {
                let tokens = shared.lock().terminals.push_tokens();
                let messages = active.tick(tokens);
                let mut state = shared.lock();
                state.hook_broker = Some(active.broker.clone());
                for message in messages {
                    state.notifications.hold(message);
                }
            } else {
                shared.lock().hook_broker = None;
            }
        }
    })
}

async fn start_and_report(shared: &Shared, files: &HookFiles) -> Option<Running> {
    match start(files).await {
        Ok(running) => {
            record_problem(shared, ProblemSource::Hooks, None);
            Some(running)
        }
        Err(reason) => {
            // Switched off again, so the setting does not claim hooks that are not there.
            let mut state = shared.lock();
            state.set_settings(|settings| settings.terminal_hooks = false);
            state.set_problem(ProblemSource::Hooks, reason);
            None
        }
    }
}

fn stop_and_report(shared: &Shared, files: &HookFiles, running: Option<Running>) -> Option<Running> {
    drop(running);
    match files.uninstall() {
        Ok(()) => record_problem(shared, ProblemSource::Hooks, None),
        Err(error) => record_problem(shared, ProblemSource::Hooks, Some(strings::hooks_could_not_remove(&error.to_string()))),
    }
    None
}

#[cfg(test)]
mod tests {
    use peering_core::terminal::hooks::broker::PushAction;

    use super::*;

    #[test]
    fn an_approval_push_carries_the_ids_the_phone_answers_with() {
        let push = HookPush {
            token: "ab".to_owned(),
            title: "Claude Code asks".to_owned(),
            body: "rm -rf build".to_owned(),
            action: Some(PushAction { category: "peering.agent.approval.tool", session_id: "S".to_owned(), approval_id: "A".to_owned() }),
        };
        let RelayClientMessage::NotifyDevice { device_token, category, session_id, approval_id, source, .. } = push_message(push) else {
            panic!("a notify message");
        };
        assert_eq!(device_token, "ab");
        assert_eq!(category.as_deref(), Some("peering.agent.approval.tool"));
        assert_eq!((session_id.as_deref(), approval_id.as_deref()), (Some("S"), Some("A")));
        assert_eq!(source, None);
    }

    #[test]
    fn a_plain_notification_carries_no_ids() {
        let push = HookPush { token: "ab".to_owned(), title: "t".to_owned(), body: "b".to_owned(), action: None };
        let RelayClientMessage::NotifyDevice { category, session_id, approval_id, .. } = push_message(push) else {
            panic!("a notify message");
        };
        assert_eq!((category, session_id, approval_id), (None, None, None));
    }

    #[test]
    fn the_phones_three_answers_map_to_the_brokers() {
        assert_eq!(answer_of(&AgentApprovalDecision::Allow {}), Answer::Allow);
        assert_eq!(answer_of(&AgentApprovalDecision::Deny {}), Answer::Deny);
        assert_eq!(answer_of(&AgentApprovalDecision::Choose { answers: vec!["a".to_owned()] }), Answer::Choose);
    }

    #[test]
    fn a_minted_token_is_32_hex_characters_and_not_repeated() {
        let first = mint_token().expect("a token");
        assert_eq!(first.len(), 32);
        assert!(first.bytes().all(|byte| byte.is_ascii_hexdigit()));
        assert_ne!(Some(first), mint_token());
    }

    #[test]
    fn a_hook_whose_runtime_has_gone_is_answered_with_nothing() {
        let (sender, inbox) = channel::<Incoming>();
        drop(inbox);
        let answered = Arc::new(Mutex::new(Vec::new()));
        let log = answered.clone();
        let event = HookEvent::parse(br#"{"hook_event_name":"Notification","session_id":"s"}"#).expect("a hook event");
        let reply: Reply = Box::new(move |line| locked(&log).push(line));
        assert!(send_to_runtime(&Mutex::new(sender), event, reply).is_err());
        assert_eq!(*locked(&answered), vec![None]);
    }

    #[test]
    fn approval_ids_are_unique() {
        let next = approval_id_source();
        assert_ne!(next(), next());
    }
}
