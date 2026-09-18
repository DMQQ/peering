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
    /// or unrecognised the client falls back to whatever its plan allows.
    ///
    /// `plan` is the client's own statement of what it has bought, one of `free`, `relay`, `plus`
    /// or `pro`. It is read leniently and in one direction: anything that is not a name the relay
    /// knows, including nothing at all, is the free allowance, and there is no spelling of
    /// "unlimited" that a client can send its way into. A plan is a hint about how much bandwidth
    /// to meter, which is why an unreadable one is not worth refusing a connection over.
    ///
    /// `jws_representation` is the proof, when the client has one: the signed transaction StoreKit
    /// handed the app for its purchase, which the relay verifies against Apple's root before
    /// believing any of it. `storekit.rs` is where that happens, including the arrangement that
    /// gives a client without one its claimed plan for now and the switch that ends it. Read
    /// leniently for the same reason the plan is: a value that is not a string is not a receipt,
    /// and a client that sends rubbish there is a client on the free allowance.
    ConnectToHost {
        host_id: String,
        client_id: String,
        protocol_version: u16,
        #[serde(default)]
        api_key: Option<String>,
        #[serde(default, deserialize_with = "optional_text")]
        plan: Option<String>,
        #[serde(default, deserialize_with = "optional_text")]
        jws_representation: Option<String>,
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

/// Reads a string field, and reads anything else as no string at all.
///
/// Used for both of the fields where a client states what it has bought, and the reading is the
/// same for both. A JSON number, object or list where a plan or a receipt should be is not an
/// error, it is nothing: a client that sends one of those is not telling the relay anything about
/// what it bought, and the one outcome that has to be impossible is a value the relay
/// half-understands being taken as a paid plan or as a receipt. `quota.rs` makes the same judgement
/// about plan strings it does not recognise, and `storekit.rs` about receipts that do not verify.
fn optional_text<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Ok(match Option::<serde_json::Value>::deserialize(deserializer)? {
        Some(serde_json::Value::String(text)) => Some(text),
        _ => None,
    })
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
                plan: None,
                jws_representation: None,
            }
        );
    }

    #[test]
    fn a_connect_request_carries_the_plan_the_client_claims() {
        let text = r#"{"type":"connectToHost","hostId":"mac","clientId":"phone","protocolVersion":3,"plan":"pro"}"#;
        let message: ClientMessage = serde_json::from_str(text).expect("should parse");
        assert_eq!(
            message,
            ClientMessage::ConnectToHost {
                host_id: "mac".into(),
                client_id: "phone".into(),
                protocol_version: 3,
                api_key: None,
                plan: Some("pro".into()),
                jws_representation: None,
            }
        );
    }

    /// The receipt beside the plan, which is the pair `storekit.rs` exists to resolve: the claim
    /// for a client with nothing to prove, and the proof for one that has it.
    #[test]
    fn a_connect_request_carries_the_receipt_beside_the_plan() {
        let text = r#"{"type":"connectToHost","hostId":"mac","clientId":"phone","protocolVersion":3,"plan":"pro","jwsRepresentation":"eyJhbGci.eyJidW5kbGUi.c2ln"}"#;
        let message: ClientMessage = serde_json::from_str(text).expect("should parse");
        let ClientMessage::ConnectToHost {
            plan,
            jws_representation,
            ..
        } = message
        else {
            panic!("expected a connect request");
        };

        assert_eq!(plan.as_deref(), Some("pro"));
        assert_eq!(
            jws_representation.as_deref(),
            Some("eyJhbGci.eyJidW5kbGUi.c2ln")
        );
    }

    /// And the same lenient read as the plan, for the same reason: whatever a client puts in that
    /// field, what reaches the verifier is either a string or nothing, and nothing is the claimed
    /// path rather than a parse failure that would refuse the connection.
    #[test]
    fn a_receipt_that_is_not_a_string_arrives_as_no_receipt() {
        for value in ["42", "null", "{}", "[\"eyJ\"]", "true"] {
            let text = format!(
                r#"{{"type":"connectToHost","hostId":"mac","clientId":"phone","protocolVersion":3,"jwsRepresentation":{value}}}"#
            );
            let message: ClientMessage = serde_json::from_str(&text).expect("should parse");
            let ClientMessage::ConnectToHost {
                jws_representation,
                ..
            } = message
            else {
                panic!("expected a connect request");
            };
            assert_eq!(jws_representation, None, "receipt {value} should read as none");
        }
    }

    /// Absent and explicitly null both have to mean "no receipt", because the two ends spell it
    /// differently: the Swift side leaves the field out and Rust's own encoder writes the null.
    #[test]
    fn a_connect_request_without_a_receipt_round_trips_as_no_receipt() {
        let message = ClientMessage::ConnectToHost {
            host_id: "mac".into(),
            client_id: "phone".into(),
            protocol_version: 3,
            api_key: None,
            plan: Some("relay".into()),
            jws_representation: None,
        };
        let json = serde_json::to_string(&message).expect("should encode");
        assert_eq!(
            serde_json::from_str::<ClientMessage>(&json).expect("should parse"),
            message
        );

        let explicit_null = r#"{"type":"connectToHost","hostId":"mac","clientId":"phone","protocolVersion":3,"plan":"relay","jwsRepresentation":null}"#;
        assert_eq!(
            serde_json::from_str::<ClientMessage>(explicit_null).expect("should parse"),
            message
        );
    }

    /// The lenient read, at the layer where it happens: whatever a client puts in that field, what
    /// arrives at the quota check is either a string it can recognise or nothing at all.
    #[test]
    fn a_plan_that_is_not_a_string_arrives_as_no_plan() {
        for value in ["42", "null", "{}", "[\"pro\"]", "true"] {
            let text = format!(
                r#"{{"type":"connectToHost","hostId":"mac","clientId":"phone","protocolVersion":3,"plan":{value}}}"#
            );
            let message: ClientMessage = serde_json::from_str(&text).expect("should parse");
            let ClientMessage::ConnectToHost { plan, .. } = message else {
                panic!("expected a connect request");
            };
            assert_eq!(plan, None, "plan {value} should read as no plan");
        }
    }

    /// A client that says nothing is metered as free rather than refused, and this is the shape
    /// that says nothing: the field left out entirely, or sent as an explicit null. The Swift side
    /// omits it; Rust's own encoder writes the null. Both have to mean None here.
    #[test]
    fn a_connect_request_without_a_plan_round_trips_as_no_plan() {
        let message = ClientMessage::ConnectToHost {
            host_id: "mac".into(),
            client_id: "phone".into(),
            protocol_version: 3,
            api_key: None,
            plan: None,
            jws_representation: None,
        };
        let json = serde_json::to_string(&message).expect("should encode");
        assert_eq!(
            serde_json::from_str::<ClientMessage>(&json).expect("should parse"),
            message
        );

        let explicit_null = r#"{"type":"connectToHost","hostId":"mac","clientId":"phone","protocolVersion":3,"plan":null}"#;
        assert_eq!(
            serde_json::from_str::<ClientMessage>(explicit_null).expect("should parse"),
            message
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
