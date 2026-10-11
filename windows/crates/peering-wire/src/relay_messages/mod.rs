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
mod tests;
