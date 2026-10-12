//! The messages that move a client's video between transports and hand it the key for the relayed lane.

use crate::swift_enum::base64_bytes;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoKeyGrant {
    #[serde(with = "base64_bytes")]
    pub secret: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum VideoTransportKind {
    Primary,
    Control,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoTransportRequest {
    pub transport: VideoTransportKind,
    pub reason: String,
}
