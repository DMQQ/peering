//! Keys and mouse buttons the client has pressed and not released. A disconnect sends their releases through the
//! sink before the sink's own `release_all`, so nothing stays down on the host.

use std::collections::{BTreeMap, BTreeSet};

use peering_wire::command::{Modifiers, MouseButton, RemoteCommand};

use crate::ports::input::{InputSink, TransformSnapshot};

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct HeldInput {
    keys: BTreeSet<u16>,
    buttons: Vec<MouseButton>,
}

impl HeldInput {
    pub fn observe(&mut self, command: &RemoteCommand) {
        match command {
            RemoteCommand::KeyDown { key_code, .. } => {
                self.keys.insert(*key_code);
            }
            RemoteCommand::KeyUp { key_code, .. } => {
                self.keys.remove(key_code);
            }
            RemoteCommand::MouseDown { button } => {
                if !self.buttons.contains(button) {
                    self.buttons.push(*button);
                }
            }
            RemoteCommand::MouseUp { button } => self.buttons.retain(|held| held != button),
            _ => {}
        }
    }

    pub fn is_empty(&self) -> bool {
        self.keys.is_empty() && self.buttons.is_empty()
    }

    /// Releases every held key and button through `input`, then calls its `release_all`.
    pub fn release_held(&mut self, transform: &TransformSnapshot, input: &mut dyn InputSink) {
        self.release_keys(transform, input);
        input.release_all();
    }

    /// Releases every held key and button through `input` and leaves the rest of the sink alone.
    pub fn release_keys(&mut self, transform: &TransformSnapshot, input: &mut dyn InputSink) {
        for key_code in std::mem::take(&mut self.keys) {
            input.apply(&RemoteCommand::KeyUp { key_code, modifiers: Modifiers::NONE }, transform);
        }
        for button in std::mem::take(&mut self.buttons) {
            input.apply(&RemoteCommand::MouseUp { button }, transform);
        }
    }
}

/// A client pings once a second, so this much silence from every session means the phone is gone, not that a key is
/// really still down.
pub const HELD_INPUT_TTL_SECONDS: f64 = 5.0;

/// What each of the host's sessions has left held, and when each was last heard from. A phone that drops without a word
/// leaves its keys down until the session is reaped, which takes a minute; this lets go of them after a few seconds. Each
/// session is judged on its own, so a second phone that is still talking does not keep a dropped phone's keys down.
#[derive(Debug, Default)]
pub struct HoldGuard {
    held: BTreeMap<u64, HeldInput>,
    last_heard: BTreeMap<u64, f64>,
}

impl HoldGuard {
    /// Any frame from an authorised session proves that session's phone is still there.
    pub fn heard(&mut self, session: u64, now: f64) {
        self.last_heard.insert(session, now);
    }

    /// Wraps `sink` so what a command leaves held is recorded against `session`.
    pub fn track<'a>(&'a mut self, session: u64, sink: &'a mut dyn InputSink) -> TrackedInput<'a> {
        TrackedInput::new(sink, self.held.entry(session).or_default())
    }

    pub fn has_held(&self) -> bool {
        self.held.values().any(|held| !held.is_empty())
    }

    /// Releases what each session holds once that session has been silent for `ttl_seconds`. The sink's own `release_all`
    /// runs only when nothing is held any more, so a session that is still talking keeps its keys. Returns true when
    /// anything was released.
    pub fn release_if_silent(
        &mut self,
        now: f64,
        ttl_seconds: f64,
        transform: &TransformSnapshot,
        input: &mut dyn InputSink,
    ) -> bool {
        let silent: Vec<u64> = self
            .held
            .iter()
            .filter(|(session, held)| !held.is_empty() && now - self.last_heard.get(session).copied().unwrap_or_default() >= ttl_seconds)
            .map(|(session, _)| *session)
            .collect();
        for session in &silent {
            if let Some(held) = self.held.get_mut(session) {
                held.release_keys(transform, input);
            }
        }
        self.held.retain(|_, held| !held.is_empty());
        self.last_heard.retain(|_, heard| now - *heard < ttl_seconds);
        if !silent.is_empty() && self.held.is_empty() {
            input.release_all();
        }
        !silent.is_empty()
    }
}

/// Forwards every command to the sink and records what it leaves held.
pub struct TrackedInput<'a> {
    sink: &'a mut dyn InputSink,
    held: &'a mut HeldInput,
}

impl<'a> TrackedInput<'a> {
    pub fn new(sink: &'a mut dyn InputSink, held: &'a mut HeldInput) -> Self {
        Self { sink, held }
    }
}

impl InputSink for TrackedInput<'_> {
    fn apply(&mut self, command: &RemoteCommand, transform: &TransformSnapshot) {
        self.held.observe(command);
        self.sink.apply(command, transform);
    }

    fn release_all(&mut self) {
        *self.held = HeldInput::default();
        self.sink.release_all();
    }
}

#[cfg(test)]
#[path = "held_input_tests.rs"]
mod tests;
