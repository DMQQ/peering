//! The `clipboardContent` payload and the size limits both ends hold it to (`RemoteCore/Clipboard.swift`).

use crate::swift_enum::base64_bytes_option;
use serde::{Deserialize, Serialize};

/// A picture the clipboard carries, at most. The Mac refuses a larger one rather than shrinking it.
pub const MAX_IMAGE_BYTES: usize = 8 * 1024 * 1024;
/// The most a chunked clipboard message may reassemble to. Above `MAX_IMAGE_BYTES` because the guard is on the base64 form.
pub const MAX_REASSEMBLED_BYTES: usize = 12 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ClipboardKind {
    Text,
    Image,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClipboardPayload {
    /// An older Mac sends `{"text": ...}` with no kind, which means text.
    #[serde(default = "text_kind")]
    pub kind: ClipboardKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    /// PNG only.
    #[serde(default, skip_serializing_if = "Option::is_none", with = "base64_bytes_option")]
    pub image: Option<Vec<u8>>,
}

fn text_kind() -> ClipboardKind {
    ClipboardKind::Text
}

impl ClipboardPayload {
    pub fn text(text: impl Into<String>) -> Self {
        Self { kind: ClipboardKind::Text, text: Some(text.into()), image: None }
    }

    pub fn image(png: Vec<u8>) -> Self {
        Self { kind: ClipboardKind::Image, text: None, image: Some(png) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_is_a_kind_and_a_text_key() {
        let json = serde_json::to_string(&ClipboardPayload::text("hi")).unwrap();
        assert_eq!(json, r#"{"kind":"text","text":"hi"}"#);
    }

    #[test]
    fn an_image_is_base64_under_the_image_key() {
        let json = serde_json::to_string(&ClipboardPayload::image(vec![1, 2, 3])).unwrap();
        assert_eq!(json, r#"{"kind":"image","image":"AQID"}"#);
    }

    #[test]
    fn a_payload_without_a_kind_reads_as_text() {
        let payload: ClipboardPayload = serde_json::from_str(r#"{"text":"old"}"#).unwrap();
        assert_eq!(payload, ClipboardPayload::text("old"));
    }
}
