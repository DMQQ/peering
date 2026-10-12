//! Control messages of the handshake and pairing exchange (protocol.md sections 5, 6 and 9).
//! Field names are the exact Swift JSON keys; `clientID` and `serverID` keep their capital ID.

use crate::swift_enum::{base64_bytes, base64_bytes_option};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub use crate::video_transport::{VideoKeyGrant, VideoTransportKind, VideoTransportRequest};

/// Declares a struct of optional capability flags. Absent or `null` reads as `None`, which means unsupported.
macro_rules! capability_flags {
    ($name:ident { $($field:ident),* $(,)? }) => {
        #[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
        #[serde(rename_all = "camelCase")]
        pub struct $name {
            $(
                #[serde(default, skip_serializing_if = "Option::is_none")]
                pub $field: Option<bool>,
            )*
        }
    };
}

capability_flags!(ClientCapabilities {
    supports_clipboard_images,
    supports_text_focus,
    supports_field_state,
    supports_pointer_report,
    supports_agent_chat,
    supports_agent_permission_modes,
    supports_agent_usage,
});

capability_flags!(ServerCapabilities {
    supports_video_pause,
    supports_clipboard_images,
    supports_mosaic,
    supports_source_thumbnails,
    supports_device_orientation,
    supports_virtual_display_management,
    pushes_terminal_alerts_while_connected,
    supports_agent_list,
    supports_agent_chat,
    supports_file_browser,
    supports_agent_model_picker,
    supports_agent_permission_modes,
    supports_agent_usage,
    supports_agent_session_import,
    supports_agent_pause,
    supports_lock_screen,
});

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientHello {
    #[serde(rename = "clientID")]
    pub client_id: String,
    pub client_name: String,
    pub protocol_version: u16,
    /// Advisory: the host decides, since only it knows its pin store.
    pub wants_pairing: bool,
    #[serde(flatten)]
    pub capabilities: ClientCapabilities,
    /// A `CaptureSource`, kept as raw JSON until the source model exists.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume_source: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lost_pairing: Option<bool>,
    /// Such as `android`. Absent from a client that predates the field.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client_platform: Option<String>,
    /// Codec names the client decodes, such as `h264`. Absent means the client takes only H.264.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video_codecs: Option<Vec<String>>,
}

impl ClientHello {
    /// The host skips pairing for a pinned key, unless the phone says it lost the pin for this Mac.
    pub fn host_treats_as_paired(client_key_is_pinned: bool, lost_pairing: Option<bool>) -> bool {
        client_key_is_pinned && lost_pairing != Some(true)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerHello {
    #[serde(rename = "serverID")]
    pub server_id: String,
    pub host_name: String,
    pub protocol_version: u16,
    pub already_paired: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mac_addresses: Option<Vec<String>>,
    #[serde(flatten)]
    pub capabilities: ServerCapabilities,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_chat_agents: Option<Vec<String>>,
    /// `windows` from this host. Absent from a host that predates the field.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_platform: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingCommit {
    #[serde(with = "base64_bytes")]
    pub commitment: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingReveal {
    #[serde(with = "base64_bytes")]
    pub ephemeral_public_key: Vec<u8>,
    #[serde(with = "base64_bytes")]
    pub nonce: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairConfirm {
    pub accepted: bool,
    /// Absent when the digits were typed rather than scanned.
    #[serde(default, skip_serializing_if = "Option::is_none", with = "base64_bytes_option")]
    pub proof: Option<Vec<u8>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairResult {
    pub accepted: bool,
    /// Present when `accepted` is false.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// A standing condition on the host. A nil `message` clears it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NoticePayload {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub symbol: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub locked_display_id: Option<u32>,
}

/// A pong is matched to its ping by this number.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PingPayload {
    pub sequence: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ErrorPayload {
    pub code: String,
    pub message: String,
}

impl ErrorPayload {
    /// The user pressed Stop on the host. The client must not reconnect.
    pub const HOST_STOPPED_CODE: &'static str = "hostStopped";
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vectors_dir::load;
    use serde::de::DeserializeOwned;

    fn round_trip<T: Serialize + DeserializeOwned>(json: &str) {
        let original: Value = serde_json::from_str(json).expect("vector is JSON");
        let parsed: T = serde_json::from_str(json).expect("vector decodes into the model");
        assert_eq!(serde_json::to_value(&parsed).expect("model encodes"), original);
    }

    #[test]
    fn every_handshake_vector_round_trips_through_its_model() {
        type VectorCheck = fn(&str);
        let table: [(&str, VectorCheck); 10] = [
            ("clientHello", round_trip::<ClientHello>),
            ("serverHello", round_trip::<ServerHello>),
            ("pairCommit", round_trip::<PairingCommit>),
            ("pairReveal", round_trip::<PairingReveal>),
            ("pairConfirm", round_trip::<PairConfirm>),
            ("pairResult", round_trip::<PairResult>),
            ("ping", round_trip::<PingPayload>),
            ("error", round_trip::<ErrorPayload>),
            ("videoKey", round_trip::<VideoKeyGrant>),
            ("videoTransport", round_trip::<VideoTransportRequest>),
        ];
        let cases = load("messages.json")["cases"].as_array().expect("cases array").clone();
        for (prefix, check) in table {
            let matching: Vec<&Value> = cases
                .iter()
                .filter(|case| case["name"].as_str().is_some_and(|name| name.starts_with(prefix)))
                .collect();
            assert!(!matching.is_empty(), "no vector named {prefix}");
            for case in matching {
                check(case["json"].as_str().expect("json text"));
            }
        }
    }

    #[test]
    fn missing_capability_flags_decode_as_none() {
        let hello: ClientHello = serde_json::from_str(r#"{"clientID":"c","clientName":"p","protocolVersion":20,"wantsPairing":false}"#).unwrap();
        assert_eq!(hello.capabilities, ClientCapabilities::default());
        assert_eq!(hello.lost_pairing, None);
        assert_eq!(hello.resume_source, None);

        let server: ServerHello = serde_json::from_str(r#"{"serverID":"s","hostName":"h","protocolVersion":20,"alreadyPaired":true}"#).unwrap();
        assert_eq!(server.capabilities, ServerCapabilities::default());
        assert_eq!(server.mac_addresses, None);
        assert_eq!(server.agent_chat_agents, None);
    }

    #[test]
    fn a_hello_with_the_platform_and_codec_list_round_trips() {
        let json = r#"{"clientID":"c","clientName":"p","protocolVersion":20,"wantsPairing":false,"clientPlatform":"android","videoCodecs":["h264","hevc"]}"#;
        let hello: ClientHello = serde_json::from_str(json).unwrap();
        assert_eq!(hello.client_platform.as_deref(), Some("android"));
        assert_eq!(hello.video_codecs, Some(vec!["h264".to_owned(), "hevc".to_owned()]));
        assert_eq!(serde_json::to_value(&hello).unwrap(), serde_json::from_str::<Value>(json).unwrap());
    }

    #[test]
    fn a_hello_from_an_older_client_has_no_platform_or_codec_list() {
        let json = r#"{"clientID":"c","clientName":"p","protocolVersion":20,"wantsPairing":false}"#;
        let hello: ClientHello = serde_json::from_str(json).unwrap();
        assert_eq!(hello.client_platform, None);
        assert_eq!(hello.video_codecs, None);
    }

    #[test]
    fn a_server_hello_carries_the_host_platform_when_it_is_set() {
        let json = r#"{"serverID":"s","hostName":"h","protocolVersion":20,"alreadyPaired":false,"hostPlatform":"windows"}"#;
        let server: ServerHello = serde_json::from_str(json).unwrap();
        assert_eq!(server.host_platform.as_deref(), Some("windows"));
        assert_eq!(serde_json::to_value(&server).unwrap(), serde_json::from_str::<Value>(json).unwrap());
    }

    #[test]
    fn unset_flags_are_absent_when_serialised() {
        let hello = ClientHello {
            client_id: "c".into(),
            client_name: "p".into(),
            protocol_version: 20,
            wants_pairing: false,
            capabilities: ClientCapabilities::default(),
            resume_source: None,
            lost_pairing: None,
            client_platform: None,
            video_codecs: None,
        };
        let value = serde_json::to_value(&hello).unwrap();
        let keys: Vec<&str> = value.as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(keys.len(), 4, "only the required keys are written: {keys:?}");
        assert!(value.get("supportsAgentChat").is_none());
        assert!(value.get("lostPairing").is_none());

        let server = ServerHello {
            server_id: "s".into(),
            host_name: "h".into(),
            protocol_version: 20,
            already_paired: true,
            mac_addresses: None,
            capabilities: ServerCapabilities::default(),
            agent_chat_agents: None,
            host_platform: None,
        };
        let value = serde_json::to_value(&server).unwrap();
        assert_eq!(value.as_object().unwrap().len(), 4);
    }

    #[test]
    fn a_pinned_key_is_trusted_unless_the_phone_lost_the_pin() {
        assert!(ClientHello::host_treats_as_paired(true, None));
        assert!(ClientHello::host_treats_as_paired(true, Some(false)));
        assert!(!ClientHello::host_treats_as_paired(true, Some(true)));
        assert!(!ClientHello::host_treats_as_paired(false, None));
        assert!(!ClientHello::host_treats_as_paired(false, Some(false)));
        assert!(!ClientHello::host_treats_as_paired(false, Some(true)));
    }
}
