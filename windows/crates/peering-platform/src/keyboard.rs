//! Keyboard half of the input sink: key presses by scancode, modifier chords and Unicode text. The builders are pure and
//! tested on any OS; `SendInput` lives in `keyboard/sys.rs`. Keys follow docs/protocol/keymap.md.

#[cfg(windows)]
use peering_core::ports::input::{InputSink, TransformSnapshot};
use peering_wire::command::{Modifiers, RemoteCommand};
use peering_wire::keymap::{mac_keycode_to_scancode, modifier_keys_for, KeyTarget};

#[cfg(windows)]
mod sys;

#[cfg(test)]
mod tests;

/// Keycodes 54 to 63 are the modifier keys themselves. They are sent as plain keys and never wrap a chord.
const MODIFIER_KEYCODES: std::ops::RangeInclusive<u16> = 54..=63;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyInput {
    Scancode(KeyTarget),
    Unicode(u16),
}

/// One `KEYBDINPUT` before it is handed to `SendInput`. `chord_modifier` marks a modifier pressed only around a key,
/// which the injector may skip when that modifier is already held by the user.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyEventSpec {
    pub input: KeyInput,
    pub key_up: bool,
    pub chord_modifier: bool,
}

/// Key events for one macOS keycode. Modifiers in `modifiers` wrap a non-modifier key: pressed before a key down and
/// released after a key up, the up order reversed. An unknown keycode yields nothing.
pub fn key_events(keycode: u16, modifiers: Modifiers, down: bool) -> Vec<KeyEventSpec> {
    let Some(target) = mac_keycode_to_scancode(keycode) else {
        return Vec::new();
    };
    let key = KeyEventSpec { input: KeyInput::Scancode(target), key_up: !down, chord_modifier: false };
    if MODIFIER_KEYCODES.contains(&keycode) {
        return vec![key];
    }
    let mut chord: Vec<KeyEventSpec> = modifier_keys_for(modifiers.0)
        .into_iter()
        .map(|modifier| KeyEventSpec { input: KeyInput::Scancode(modifier), key_up: !down, chord_modifier: true })
        .collect();
    if down {
        chord.push(key);
        chord
    } else {
        let mut out = vec![key];
        out.extend(chord.into_iter().rev());
        out
    }
}

/// Each UTF-16 unit is pressed and released in turn, so a surrogate pair stays two adjacent units and is never reordered.
pub fn unicode_events(text: &str) -> Vec<KeyEventSpec> {
    let mut events = Vec::with_capacity(text.len() * 2);
    for unit in text.encode_utf16() {
        for key_up in [false, true] {
            events.push(KeyEventSpec { input: KeyInput::Unicode(unit), key_up, chord_modifier: false });
        }
    }
    events
}

/// Keys the host has pressed and not yet released, plus the modifiers each non-modifier key pressed for its chord.
#[derive(Debug, Default)]
pub struct HeldKeys {
    keys: Vec<KeyTarget>,
    chords: Vec<(u16, Vec<KeyTarget>)>,
}

impl HeldKeys {
    fn is_held(&self, target: KeyTarget) -> bool {
        self.keys.contains(&target)
    }

    fn hold(&mut self, target: KeyTarget) {
        if !self.is_held(target) {
            self.keys.push(target);
        }
    }

    fn unhold(&mut self, target: KeyTarget) {
        self.keys.retain(|held| *held != target);
    }

    /// Records modifiers this key's chord pressed. A repeated key down adds to the same entry, so nothing is lost on release.
    fn record_chord(&mut self, keycode: u16, pressed: &[KeyTarget]) {
        if pressed.is_empty() {
            return;
        }
        match self.chords.iter_mut().find(|(code, _)| *code == keycode) {
            Some((_, existing)) => existing.extend_from_slice(pressed),
            None => self.chords.push((keycode, pressed.to_vec())),
        }
    }

    fn take_chord(&mut self, keycode: u16) -> Vec<KeyTarget> {
        match self.chords.iter().position(|(code, _)| *code == keycode) {
            Some(index) => self.chords.remove(index).1,
            None => Vec::new(),
        }
    }

    /// Releases every held key, last pressed first, and forgets all chords.
    fn release_all(&mut self) -> Vec<KeyEventSpec> {
        self.chords.clear();
        self.keys.drain(..).rev().map(|target| scancode_spec(target, true, false)).collect()
    }
}

fn scancode_spec(target: KeyTarget, key_up: bool, chord_modifier: bool) -> KeyEventSpec {
    KeyEventSpec { input: KeyInput::Scancode(target), key_up, chord_modifier }
}

/// Builds the key events for each command and tracks what is down, so a disconnect can release it.
#[derive(Debug, Default)]
pub struct KeyboardInjector {
    held: HeldKeys,
}

impl KeyboardInjector {
    pub fn plan(&mut self, command: &RemoteCommand) -> Vec<KeyEventSpec> {
        match command {
            RemoteCommand::KeyDown { key_code, modifiers } => self.plan_key(*key_code, *modifiers, true),
            RemoteCommand::KeyUp { key_code, modifiers } => self.plan_key(*key_code, *modifiers, false),
            RemoteCommand::TextInput { text } => unicode_events(text),
            _ => Vec::new(),
        }
    }

    pub fn release_events(&mut self) -> Vec<KeyEventSpec> {
        self.held.release_all()
    }

    /// Chord modifiers the user already holds are neither pressed nor released here, so a Command-C chord cannot lift
    /// a Control that the user is still holding.
    fn plan_key(&mut self, keycode: u16, modifiers: Modifiers, down: bool) -> Vec<KeyEventSpec> {
        let (chord, keys): (Vec<KeyEventSpec>, Vec<KeyEventSpec>) =
            key_events(keycode, modifiers, down).into_iter().partition(|spec| spec.chord_modifier);
        let mut out = Vec::new();
        if down {
            let pressed = self.press_chord(&chord);
            self.held.record_chord(keycode, &pressed);
            out.extend(pressed.iter().map(|target| scancode_spec(*target, false, true)));
            out.extend(keys.iter().map(|spec| self.track_key(*spec)));
        } else {
            out.extend(keys.iter().map(|spec| self.track_key(*spec)));
            for target in self.held.take_chord(keycode).into_iter().rev() {
                self.held.unhold(target);
                out.push(scancode_spec(target, true, true));
            }
        }
        out
    }

    fn press_chord(&mut self, chord: &[KeyEventSpec]) -> Vec<KeyTarget> {
        let mut pressed = Vec::new();
        for spec in chord {
            let KeyInput::Scancode(target) = spec.input else {
                continue;
            };
            if !self.held.is_held(target) {
                self.held.hold(target);
                pressed.push(target);
            }
        }
        pressed
    }

    fn track_key(&mut self, spec: KeyEventSpec) -> KeyEventSpec {
        if let KeyInput::Scancode(target) = spec.input {
            if spec.key_up {
                self.held.unhold(target);
            } else {
                self.held.hold(target);
            }
        }
        spec
    }
}

#[cfg(windows)]
impl InputSink for KeyboardInjector {
    fn apply(&mut self, command: &RemoteCommand, _transform: &TransformSnapshot) {
        let events = self.plan(command);
        sys::send(&events);
    }

    fn release_all(&mut self) {
        let events = self.release_events();
        sys::send(&events);
    }
}
