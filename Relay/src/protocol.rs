//! The signalling conversation, as JSON over a WebSocket.
//!
//! This is the only place the two ends and the relay have to agree on a shape, and it is
//! deliberately the smallest part of the system. Signalling carries no media — it introduces two
//! parties and hands out the endpoints they will actually use. Once a session exists, nothing the
//! relay says can affect what the two ends do with it, because every byte that matters is already
//! authenticated between them.
//!
//! Field names are camelCase because the other end is Swift, where `JSONEncoder`'s default is the
//! property name unchanged.

use serde::{Deserialize, Serialize};

use crate::session::Token;

/// What a client — either a Mac or a phone — sends to the relay.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum ClientMessage {
    /// A Mac announcing itself. Holding this connection open *is* the Mac's presence: when it
    /// drops, the Mac is offline, and it re-registers when it comes back — on a new address, under
    /// the same device ID.
    RegisterHost {
        device_id: String,
        name: String,
        protocol_version: u16,
    },

    /// A phone asking where its Mac is.
    ///
    /// `client_id` is the phone's own device ID, which it already broadcasts in its Bonjour TXT
    /// record and which is not a secret. The relay wants it for one reason: to recognise a
    /// reconnecting phone and supersede its previous session rather than accumulate one per
    /// attempt. Nothing here is authorization — see `session.rs`.
    ///
    /// `api_key` is optional. When present and valid it grants unlimited relay time; when absent
    /// or unrecognised the client falls back to the free monthly allowance.
    ConnectToHost {
        host_id: String,
        client_id: String,
        protocol_version: u16,
        #[serde(default)]
        api_key: Option<String>,
    },

    /// Keeps the signalling connection alive through idle NAT timeouts.
    Ping,
}

/// What the relay sends back.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum ServerMessage {
    /// A host registration was accepted.
    Registered { session_ttl_seconds: u64 },

    /// A session is ready. Sent to the phone that asked and pushed to the Mac it asked for, with
    /// identical contents, because both need exactly the same four things: where to connect and
    /// what to present when they get there.
    ///
    /// The control token is single-use; the video token is reusable, because a NAT mapping can
    /// change mid-session and the binding has to be re-established. See `session.rs`.
    SessionReady {
        control_host: String,
        control_port: u16,
        video_host: String,
        video_port: u16,
        /// Hex.
        control_token: String,
        /// Hex.
        video_token: String,
    },

    /// The Mac is not registered. It is asleep, off, or has not been launched.
    HostOffline { device_id: String },

    Pong,

    Error { code: String, message: String },
}

impl ServerMessage {
    pub fn error(code: &str, message: impl Into<String>) -> Self {
        Self::Error {
            code: code.to_string(),
            message: message.into(),
        }
    }
}

/// Hex, because it needs no dependency, is trivially readable in a log, and these are 16 bytes that
/// travel inside TLS.
pub fn hex(bytes: &Token) -> String {
    use std::fmt::Write;
    bytes
        .iter()
        .fold(String::with_capacity(bytes.len() * 2), |mut out, b| {
            let _ = write!(out, "{b:02x}");
            out
        })
}

pub fn unhex(text: &str) -> Option<Token> {
    if text.len() != 32 {
        return None;
    }
    let mut out = [0u8; 16];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(text.get(i * 2..i * 2 + 2)?, 16).ok()?;
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_host_registration_round_trips_through_camel_case() {
        let text = r#"{"type":"registerHost","deviceId":"abc","name":"Studio","protocolVersion":3}"#;
        let message: ClientMessage = serde_json::from_str(text).expect("should parse");
        assert_eq!(
            message,
            ClientMessage::RegisterHost {
                device_id: "abc".into(),
                name: "Studio".into(),
                protocol_version: 3,
            }
        );
    }

    #[test]
    fn a_connect_request_round_trips_through_camel_case() {
        let text =
            r#"{"type":"connectToHost","hostId":"mac","clientId":"phone","protocolVersion":3}"#;
        let message: ClientMessage = serde_json::from_str(text).expect("should parse");
        assert_eq!(
            message,
            ClientMessage::ConnectToHost {
                host_id: "mac".into(),
                client_id: "phone".into(),
                protocol_version: 3,
                api_key: None,
            }
        );
    }

    #[test]
    fn session_ready_reports_its_endpoints_in_the_case_swift_expects() {
        let message = ServerMessage::SessionReady {
            control_host: "relay.example".into(),
            control_port: 9443,
            video_host: "relay.example".into(),
            video_port: 51234,
            control_token: hex(&[0xab; 16]),
            video_token: hex(&[0xcd; 16]),
        };
        let json = serde_json::to_string(&message).expect("should encode");

        for key in [
            "controlHost",
            "controlPort",
            "videoHost",
            "videoPort",
            "controlToken",
            "videoToken",
        ] {
            assert!(json.contains(key), "missing {key} in {json}");
        }
    }

    /// The Swift side decodes these by name, so a rename here is a silent break at runtime rather
    /// than a compile error there. This pins the tag as well as the fields.
    #[test]
    fn the_message_tag_is_the_swift_case_name() {
        let json = serde_json::to_string(&ServerMessage::Pong).unwrap();
        assert_eq!(json, r#"{"type":"pong"}"#);

        let json = serde_json::to_string(&ServerMessage::HostOffline {
            device_id: "abc".into(),
        })
        .unwrap();
        assert_eq!(json, r#"{"type":"hostOffline","deviceId":"abc"}"#);
    }

    #[test]
    fn tokens_survive_a_round_trip_and_rubbish_is_refused() {
        let token = [
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54,
            0x32, 0x10,
        ];
        assert_eq!(unhex(&hex(&token)), Some(token));

        assert_eq!(unhex(""), None);
        assert_eq!(unhex("abcd"), None, "too short");
        assert_eq!(unhex(&"z".repeat(32)), None, "not hex");
        assert_eq!(unhex(&"a".repeat(33)), None, "too long");
        assert_eq!(unhex(&"aB".repeat(16)), Some([0xab; 16]), "either case");
    }
}
