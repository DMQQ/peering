//! The `textFocus` (0x1C) and `fieldState` (0x1D) payloads (`RemoteCore/TextFocus.swift`), sent only to a client that declared
//! `supportsTextFocus` or `supportsFieldState`.

use crate::source::NormalizedPoint;
use serde::{Deserialize, Serialize};

/// Whether the keyboard focus on the host is somewhere that takes typing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextFocus {
    pub is_editable: bool,
}

/// What the focused text field holds and where the insertion point is. The selection counts UTF-16 units, as the Mac's
/// accessibility API does and the phones' text fields expect.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FieldState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    pub selection_location: u32,
    pub selection_length: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub caret: Option<NormalizedPoint>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_focus_uses_the_swift_key() {
        assert_eq!(serde_json::to_string(&TextFocus { is_editable: true }).unwrap(), r#"{"isEditable":true}"#);
        assert_eq!(serde_json::from_str::<TextFocus>(r#"{"isEditable":false}"#).unwrap(), TextFocus { is_editable: false });
    }

    #[test]
    fn a_field_without_text_or_caret_leaves_those_keys_out() {
        let state = FieldState { text: None, selection_location: 0, selection_length: 0, caret: None };
        assert_eq!(serde_json::to_string(&state).unwrap(), r#"{"selectionLocation":0,"selectionLength":0}"#);
    }

    #[test]
    fn a_full_field_state_round_trips() {
        let state = FieldState {
            text: Some("héllo".to_owned()),
            selection_location: 2,
            selection_length: 3,
            caret: Some(NormalizedPoint { x: 0.25, y: 0.5 }),
        };
        let json = serde_json::to_string(&state).unwrap();
        assert_eq!(json, r#"{"text":"héllo","selectionLocation":2,"selectionLength":3,"caret":{"x":0.25,"y":0.5}}"#);
        assert_eq!(serde_json::from_str::<FieldState>(&json).unwrap(), state);
    }

    #[test]
    fn a_null_text_reads_as_none() {
        let parsed: FieldState = serde_json::from_str(r#"{"text":null,"selectionLocation":1,"selectionLength":0,"caret":null}"#).unwrap();
        assert_eq!(parsed.text, None);
        assert_eq!(parsed.caret, None);
    }
}
