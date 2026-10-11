//! Relay signalling messages, the JSON shapes exchanged over the signalling WebSocket. See docs/protocol/relay.md section 1.

use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// Sixteen bytes, spelled on the wire as exactly thirty-two ASCII hex digits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Token(pub [u8; 16]);

impl Token {
    /// Strict: the length is checked before decoding and every byte must be an ASCII hex digit, so a
    /// leading `+` or any other character the hex decoder might tolerate is refused.
    pub fn parse(text: &str) -> Option<Self> {
        if text.len() != 32 || !text.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return None;
        }
        let decoded = hex::decode(text).ok()?;
        let bytes: [u8; 16] = decoded.try_into().ok()?;
        Some(Self(bytes))
    }

    pub fn to_hex(self) -> String {
        hex::encode(self.0)
    }
}

impl Serialize for Token {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.to_hex())
    }
}

impl<'de> Deserialize<'de> for Token {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        Token::parse(&text).ok_or_else(|| D::Error::custom("token is not 32 hex digits"))
    }
}

/// Messages a Mac or a phone sends to the relay. Optional fields are left out of the JSON when `None`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum RelayClientMessage {
    RegisterHost {
        device_id: String,
        name: String,
        protocol_version: u16,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        public_key: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        proof: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        proof_time: Option<u64>,
    },
    ConnectToHost {
        host_id: String,
        client_id: String,
        protocol_version: u16,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        api_key: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        plan: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        jws_representation: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        public_key: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        proof: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        proof_time: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        play_purchase_token: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        play_product_id: Option<String>,
    },
    RequestPeerAddress {
        video_token: String,
    },
    HostPresence {
        host_id: String,
    },
    Ping,
    NotifyDevice {
        device_token: String,
        title: String,
        body: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        source: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        category: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        approval_id: Option<String>,
    },
}

/// Messages the relay sends back. A `type` this build does not know decodes as `Unknown`, which the caller ignores.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum RelayServerMessage {
    Registered {
        session_ttl_seconds: u64,
    },
    SessionReady {
        control_host: String,
        control_port: u16,
        video_host: String,
        video_port: u16,
        control_token: Token,
        video_token: Token,
    },
    HostOffline {
        device_id: String,
    },
    PeerAddress {
        host: String,
        port: u16,
    },
    HostPresence {
        host_id: String,
        online: bool,
    },
    Pong,
    Error {
        code: String,
        message: String,
    },
    #[serde(other)]
    Unknown,
}

/// Compact JSON with keys in sorted order. `serde_json::Value` objects are BTreeMaps unless the
/// `preserve_order` feature is on, which this crate does not enable.
pub fn encode_sorted(message: &impl Serialize) -> String {
    let value = serde_json::to_value(message).expect("relay messages hold only strings and integers");
    serde_json::to_string(&value).expect("a JSON value always serialises")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vectors_dir::load;

    fn typed_client_message(name: &str) -> RelayClientMessage {
        match name {
            "registerHost" => RelayClientMessage::RegisterHost {
                device_id: "mac-1".into(),
                name: "Studio".into(),
                protocol_version: 3,
                public_key: None,
                proof: None,
                proof_time: None,
            },
            "connectToHost free" => connect_to_host(None),
            "connectToHost plan" => connect_to_host(Some("relay")),
            "ping" => RelayClientMessage::Ping,
            "requestPeerAddress" => RelayClientMessage::RequestPeerAddress {
                video_token: "000102030405060708090a0b0c0d0e0f".into(),
            },
            "hostPresence" => RelayClientMessage::HostPresence { host_id: "mac-1".into() },
            "notifyDevice" => RelayClientMessage::NotifyDevice {
                device_token: "ab".repeat(32),
                title: "t".into(),
                body: "b".into(),
                source: None,
                category: None,
                session_id: None,
                approval_id: None,
            },
            other => panic!("no typed message for vector {other}"),
        }
    }

    fn connect_to_host(plan: Option<&str>) -> RelayClientMessage {
        RelayClientMessage::ConnectToHost {
            host_id: "mac-1".into(),
            client_id: "phone-1".into(),
            protocol_version: 3,
            api_key: None,
            plan: plan.map(str::to_string),
            jws_representation: None,
            public_key: None,
            proof: None,
            proof_time: None,
            play_purchase_token: None,
            play_product_id: None,
        }
    }

    fn typed_server_message(name: &str) -> RelayServerMessage {
        match name {
            "sessionReady" => RelayServerMessage::SessionReady {
                control_host: "relay.getpeering.app".into(),
                control_port: 20190,
                video_host: "relay.getpeering.app".into(),
                video_port: 30190,
                control_token: Token(std::array::from_fn(|index| index as u8)),
                video_token: Token(std::array::from_fn(|index| 0xff - index as u8)),
            },
            "registered" => RelayServerMessage::Registered { session_ttl_seconds: 300 },
            "hostOffline" => RelayServerMessage::HostOffline { device_id: "mac-1".into() },
            "peerAddress" => RelayServerMessage::PeerAddress { host: "203.0.113.5".into(), port: 40000 },
            "hostPresence" => RelayServerMessage::HostPresence { host_id: "mac-1".into(), online: true },
            "pong" => RelayServerMessage::Pong,
            "error" => RelayServerMessage::Error {
                code: "quotaExceeded".into(),
                message: "relay allowance exhausted for this period".into(),
            },
            other => panic!("no typed message for vector {other}"),
        }
    }

    fn vector_entries(section: &str) -> Vec<(String, String)> {
        let vectors = load("relay.json");
        vectors[section]
            .as_array()
            .expect("section is a list")
            .iter()
            .map(|entry| {
                (
                    entry["name"].as_str().expect("name").to_string(),
                    entry["json"].as_str().expect("json").to_string(),
                )
            })
            .collect()
    }

    #[test]
    fn every_client_vector_serialises_to_its_exact_json() {
        let entries = vector_entries("clientMessages");
        assert_eq!(entries.len(), 7);
        for (name, json) in entries {
            assert_eq!(encode_sorted(&typed_client_message(&name)), json, "vector {name}");
        }
    }

    #[test]
    fn every_server_vector_decodes_to_the_typed_message() {
        let entries = vector_entries("serverMessages");
        assert_eq!(entries.len(), 7);
        for (name, json) in entries {
            let decoded: RelayServerMessage = serde_json::from_str(&json).expect("vector decodes");
            assert_eq!(decoded, typed_server_message(&name), "vector {name}");
        }
    }

    #[test]
    fn valid_tokens_parse_and_print_lowercase() {
        let vectors = load("relay.json");
        for text in vectors["tokens"]["valid"].as_array().expect("valid list") {
            let text = text.as_str().expect("token text");
            let token = Token::parse(text).expect("valid token parses");
            assert_eq!(token.to_hex(), text.to_ascii_lowercase());
        }
    }

    #[test]
    fn invalid_tokens_are_refused() {
        let vectors = load("relay.json");
        for text in vectors["tokens"]["invalid"].as_array().expect("invalid list") {
            let text = text.as_str().expect("token text");
            assert!(Token::parse(text).is_none(), "accepted {text:?}");
        }
    }

    #[test]
    fn a_session_ready_with_a_bad_token_fails_to_decode() {
        let json = r#"{"type":"sessionReady","controlHost":"h","controlPort":1,"videoHost":"h","videoPort":2,"controlToken":"+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1","videoToken":"000102030405060708090a0b0c0d0e0f"}"#;
        assert!(serde_json::from_str::<RelayServerMessage>(json).is_err());
    }

    #[test]
    fn unknown_server_type_decodes_as_unknown() {
        let decoded: RelayServerMessage =
            serde_json::from_str(r#"{"type":"somethingNew","extra":1}"#).expect("unknown type decodes");
        assert_eq!(decoded, RelayServerMessage::Unknown);
    }

    #[test]
    fn unset_optional_fields_are_absent_from_the_json() {
        let message = RelayClientMessage::RegisterHost {
            device_id: "d".into(),
            name: "n".into(),
            protocol_version: 20,
            public_key: None,
            proof: None,
            proof_time: None,
        };
        assert_eq!(
            encode_sorted(&message),
            r#"{"deviceId":"d","name":"n","protocolVersion":20,"type":"registerHost"}"#
        );
    }

    #[test]
    fn set_optional_fields_appear_in_the_json() {
        let message = RelayClientMessage::RegisterHost {
            device_id: "d".into(),
            name: "n".into(),
            protocol_version: 20,
            public_key: Some("04aa".into()),
            proof: Some("3044".into()),
            proof_time: Some(1760000000),
        };
        assert_eq!(
            encode_sorted(&message),
            r#"{"deviceId":"d","name":"n","proof":"3044","proofTime":1760000000,"protocolVersion":20,"publicKey":"04aa","type":"registerHost"}"#
        );
    }
}
