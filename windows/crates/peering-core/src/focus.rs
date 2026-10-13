//! Decides what the phone is told about the PC's keyboard focus, as `TextFocusWatcher.swift` does on the Mac: a `textFocus`
//! when the focus moves (so the phone can raise its keyboard for a text field) and a `fieldState` while the focused field
//! changes. Where focus already is when watching starts is recorded and not sent, because only a move the person makes
//! should open the phone's keyboard.

use peering_wire::source::NormalizedPoint;
use peering_wire::text_focus::{FieldState, TextFocus};

use crate::pointer::unclamped;
use crate::ports::focus::{FocusReport, FocusSnapshot};
use crate::ports::input::TransformSnapshot;

/// Past this many UTF-16 units a field is a document, and sending it whole every time it changes is the wrong trade.
pub const LONGEST_READABLE_TEXT: usize = 8000;

#[derive(Debug, Clone, PartialEq)]
pub enum FocusMessage {
    Focus(TextFocus),
    Field(FieldState),
}

#[derive(Debug, Default)]
pub struct FocusWatcher {
    started: bool,
    element: Option<u64>,
    last_field: Option<FieldState>,
}

impl FocusWatcher {
    /// Forgets everything, for when no phone wants to know. The next look is a new baseline.
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    pub fn on_report(&mut self, report: &FocusReport, transform: &TransformSnapshot) -> Vec<FocusMessage> {
        match report {
            FocusReport::Focus(snapshot) => self.on_focus(snapshot.as_ref(), transform),
            FocusReport::Tapped { editable } => {
                if self.started {
                    vec![FocusMessage::Focus(TextFocus { is_editable: *editable })]
                } else {
                    Vec::new()
                }
            }
        }
    }

    fn on_focus(&mut self, snapshot: Option<&FocusSnapshot>, transform: &TransformSnapshot) -> Vec<FocusMessage> {
        if !self.started {
            self.started = true;
            self.element = snapshot.map(|snapshot| snapshot.element);
            return Vec::new();
        }
        let element = snapshot.map(|snapshot| snapshot.element);
        let Some(snapshot) = snapshot else {
            if self.element.take().is_none() {
                return Vec::new();
            }
            self.last_field = None;
            return vec![FocusMessage::Focus(TextFocus { is_editable: false })];
        };
        let mut messages = Vec::new();
        if element != self.element {
            self.element = element;
            self.last_field = None;
            messages.push(FocusMessage::Focus(TextFocus { is_editable: snapshot.editable }));
        }
        if snapshot.editable {
            let state = field_state(snapshot, transform);
            if self.last_field.as_ref() != Some(&state) {
                self.last_field = Some(state.clone());
                messages.push(FocusMessage::Field(state));
            }
        }
        messages
    }
}

fn field_state(snapshot: &FocusSnapshot, transform: &TransformSnapshot) -> FieldState {
    let text = snapshot
        .text
        .as_ref()
        .filter(|text| !snapshot.secure && !snapshot.terminal && text.encode_utf16().count() <= LONGEST_READABLE_TEXT)
        .cloned();
    let (location, length) = snapshot
        .selection
        .or_else(|| text.as_ref().map(|text| (text.encode_utf16().count() as u32, 0)))
        .unwrap_or((0, 0));
    let caret = if snapshot.secure { None } else { snapshot.caret.and_then(|at| inside(at, transform)) };
    FieldState { text, selection_location: location, selection_length: length, caret }
}

fn inside(global: (f64, f64), transform: &TransformSnapshot) -> Option<NormalizedPoint> {
    let (x, y) = unclamped(global, transform);
    ((0.0..=1.0).contains(&x) && (0.0..=1.0).contains(&y)).then_some(NormalizedPoint { x, y })
}

#[cfg(test)]
mod tests;
