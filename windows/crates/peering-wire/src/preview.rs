//! The web preview proxy: the phone's requests for a server on the host's own loopback, and the answers in pieces.
//! Mirrors `PreviewProxy.swift` in RemoteCore.

use crate::swift_enum::{base64_bytes, base64_bytes_option};
use serde::{Deserialize, Serialize};

pub const MAX_REQUEST_BODY_BYTES: usize = 256 * 1024;
/// A request frame is JSON with the body in base64, so this leaves room for it plus headers.
pub const MAX_REQUEST_FRAME_BYTES: usize = 512 * 1024;
pub const MAX_RESPONSE_BYTES: usize = 8 * 1024 * 1024;
pub const CHUNK_BYTES: usize = 48 * 1024;
pub const MAX_HEADER_COUNT: usize = 64;
pub const MAX_TARGET_LENGTH: usize = 8 * 1024;
pub const MAX_IN_FLIGHT_PER_CLIENT: usize = 16;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreviewHeader {
    pub name: String,
    pub value: String,
}

/// There is no host field on purpose: the host always dials `127.0.0.1`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreviewProxyRequest {
    pub id: u32,
    pub port: u16,
    pub method: String,
    /// Path and query, starting with a single `/`.
    pub target: String,
    pub headers: Vec<PreviewHeader>,
    #[serde(default, with = "base64_bytes_option", skip_serializing_if = "Option::is_none")]
    pub body: Option<Vec<u8>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum PreviewProxyCommand {
    Fetch {
        #[serde(rename = "_0")]
        request: PreviewProxyRequest,
    },
    Cancel {
        id: u32,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PreviewFailure {
    InvalidRequest,
    NotAllowed,
    NotListening,
    TimedOut,
    TooLarge,
    Busy,
    Disconnected,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum PreviewProxyEvent {
    Head {
        id: u32,
        status: i64,
        headers: Vec<PreviewHeader>,
    },
    Body {
        id: u32,
        #[serde(with = "base64_bytes")]
        data: Vec<u8>,
    },
    /// `truncated` means the body hit `MAX_RESPONSE_BYTES` and the rest was dropped.
    End {
        id: u32,
        truncated: bool,
    },
    Failure {
        id: u32,
        reason: PreviewFailure,
    },
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::de::DeserializeOwned;
    use serde_json::Value;

    fn assert_wire<T: Serialize + DeserializeOwned>(json: &str) {
        let expected: Value = serde_json::from_str(json).expect("JSON");
        let decoded: T = serde_json::from_value(expected.clone()).expect("decodes");
        assert_eq!(serde_json::to_value(&decoded).expect("encodes"), expected);
    }

    #[test]
    fn a_fetch_with_a_body_and_a_cancel_match_the_swift_encoding() {
        assert_wire::<PreviewProxyCommand>(
            r#"{"fetch":{"_0":{"id":7,"port":3000,"method":"POST","target":"/a?b=1","headers":[{"name":"Accept","value":"*/*"}],"body":"aGk="}}}"#,
        );
        assert_wire::<PreviewProxyCommand>(r#"{"fetch":{"_0":{"id":1,"port":5173,"method":"GET","target":"/","headers":[]}}}"#);
        assert_wire::<PreviewProxyCommand>(r#"{"cancel":{"id":7}}"#);
    }

    #[test]
    fn every_event_matches_the_swift_encoding() {
        assert_wire::<PreviewProxyEvent>(r#"{"head":{"id":1,"status":200,"headers":[{"name":"Content-Type","value":"text/html"}]}}"#);
        assert_wire::<PreviewProxyEvent>(r#"{"body":{"id":1,"data":"AAEC"}}"#);
        assert_wire::<PreviewProxyEvent>(r#"{"end":{"id":1,"truncated":false}}"#);
        assert_wire::<PreviewProxyEvent>(r#"{"failure":{"id":1,"reason":"notListening"}}"#);
    }
}
