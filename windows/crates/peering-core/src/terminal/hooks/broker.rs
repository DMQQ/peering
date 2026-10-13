//! Turns a Claude Code hook into a notification on the phone and, for a permission request, holds the hook until the
//! phone answers. Time and the phone are injected, so a test drives it without waiting.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};

use super::event::{HookEvent, HookKind};
use super::reply::{permission_reply, HookDecision};
use super::settings::PERMISSION_TIMEOUT_SECONDS;
use crate::ports::clock::Clock;

/// Short of the hook's own timeout, so the answer to a request nobody took is Claude Code's dialog and not a killed hook.
pub const HOLD_SECONDS: f64 = (PERMISSION_TIMEOUT_SECONDS - 10) as f64;
/// A longer command is cut on a lock screen, so Allow there would approve what the person did not read.
const MAXIMUM_BODY_CHARACTERS: usize = 240;
pub const TOOL_CATEGORY: &str = "peering.agent.approval.tool";
pub const OPEN_CATEGORY: &str = "peering.agent.approval.open";

/// What the hook process prints: one JSON line, or nothing so that Claude Code shows its own dialog.
pub type Reply = Box<dyn FnOnce(Option<Vec<u8>>) + Send>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Answer {
    Allow,
    Deny,
    /// An option picked in the app: nothing a hook can express, so the terminal asks.
    Choose,
}

/// What a notification button reports back with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushAction {
    pub category: &'static str,
    pub session_id: String,
    pub approval_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookPush {
    pub token: String,
    pub title: String,
    pub body: String,
    pub action: Option<PushAction>,
}

/// The phones that can be told, and the way to tell one.
pub trait Phones: Send + Sync {
    fn tokens(&self) -> Vec<String>;
    fn push(&self, push: HookPush);
}

struct Held {
    reply: Reply,
    expires_at: f64,
}

pub struct HookBroker {
    phones: Arc<dyn Phones>,
    clock: Arc<dyn Clock + Send + Sync>,
    new_id: Box<dyn Fn() -> String + Send + Sync>,
    /// No reply or push runs while this is held.
    held: Mutex<HashMap<String, Held>>,
}

impl HookBroker {
    pub fn new(
        phones: Arc<dyn Phones>,
        clock: Arc<dyn Clock + Send + Sync>,
        new_id: Box<dyn Fn() -> String + Send + Sync>,
    ) -> Self {
        Self { phones, clock, new_id, held: Mutex::new(HashMap::new()) }
    }

    pub fn handle(&self, event: &HookEvent, reply: Reply) {
        let tokens = self.phones.tokens();
        match event.kind {
            HookKind::PermissionRequest => self.permission_request(event, &tokens, reply),
            HookKind::Notification => {
                let body = event.message.clone().unwrap_or_else(|| "Claude Code is waiting for you.".to_owned());
                self.push_all(&tokens, &title_for(event), &body, None);
                reply(None);
            }
            HookKind::Other(_) => reply(None),
        }
    }

    /// True when `approval_id` was a held hook, which is then answered.
    pub fn resolve(&self, approval_id: &str, answer: Answer) -> bool {
        let Some(held) = self.lock().remove(approval_id) else {
            return false;
        };
        (held.reply)(match answer {
            Answer::Allow => Some(permission_reply(HookDecision::Allow)),
            Answer::Deny => Some(permission_reply(HookDecision::Deny)),
            Answer::Choose => None,
        });
        true
    }

    /// Lets every request nobody answered in time fall back to the terminal dialog. The caller ticks this.
    pub fn expire(&self) -> usize {
        let now = self.clock.now_seconds();
        let expired: Vec<Held> = {
            let mut held = self.lock();
            let ids: Vec<String> = held.iter().filter(|(_, entry)| entry.expires_at <= now).map(|(id, _)| id.clone()).collect();
            ids.iter().filter_map(|id| held.remove(id)).collect()
        };
        let count = expired.len();
        for entry in expired {
            (entry.reply)(None);
        }
        count
    }

    fn permission_request(&self, event: &HookEvent, tokens: &[String], reply: Reply) {
        if tokens.is_empty() {
            reply(None);
            return;
        }
        let approval_id = (self.new_id)();
        let whole_command = shows_whole_command(event.detail.as_deref());
        let category = if whole_command { TOOL_CATEGORY } else { OPEN_CATEGORY };
        let holds = event.can_be_answered_from_a_notification() && whole_command;
        let body = event.detail.as_deref().map(truncated).filter(|text| !text.is_empty());
        let action = PushAction { category, session_id: event.session_id.clone(), approval_id: approval_id.clone() };
        if holds {
            let expires_at = self.clock.now_seconds() + HOLD_SECONDS;
            self.lock().insert(approval_id, Held { reply, expires_at });
        } else {
            reply(None);
        }
        let title = format!("{} asks", title_for(event));
        self.push_all(tokens, &title, body.as_deref().unwrap_or("Needs your approval."), Some(action));
    }

    fn push_all(&self, tokens: &[String], title: &str, body: &str, action: Option<PushAction>) {
        for token in tokens {
            self.phones.push(HookPush { token: token.clone(), title: title.to_owned(), body: body.to_owned(), action: action.clone() });
        }
    }

    fn lock(&self) -> MutexGuard<'_, HashMap<String, Held>> {
        self.held.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

fn title_for(event: &HookEvent) -> String {
    event.project_name().map_or_else(|| "Claude Code".to_owned(), |name| format!("Claude Code in {name}"))
}

fn shows_whole_command(detail: Option<&str>) -> bool {
    detail.map(str::trim).is_some_and(|text| !text.is_empty() && text.chars().count() < MAXIMUM_BODY_CHARACTERS)
}

fn truncated(text: &str) -> String {
    let trimmed = text.trim();
    if trimmed.chars().count() <= MAXIMUM_BODY_CHARACTERS {
        return trimmed.to_owned();
    }
    let cut: String = trimmed.chars().take(MAXIMUM_BODY_CHARACTERS - 1).collect();
    format!("{}\u{2026}", cut.trim_end())
}

#[cfg(test)]
mod tests;
