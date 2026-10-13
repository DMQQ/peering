use crate::files::RemoteFileOperation;
use crate::swift_enum::base64_bytes;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum TerminalRequest {
    List {},
    Agents {},
    Create {},
    Input {
        #[serde(rename = "sessionID")]
        session_id: String,
        #[serde(with = "base64_bytes")]
        data: Vec<u8>,
    },
    Resize {
        #[serde(rename = "sessionID")]
        session_id: String,
        columns: u16,
        rows: u16,
    },
    Rename {
        #[serde(rename = "sessionID")]
        session_id: String,
        name: String,
    },
    Retitle {
        #[serde(rename = "sessionID")]
        session_id: String,
        command: String,
    },
    Close {
        #[serde(rename = "sessionID")]
        session_id: String,
    },
    StartBrowser {
        id: String,
    },
    ListDirectory {
        #[serde(rename = "sessionID")]
        session_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        path: Option<String>,
    },
    ReadFile {
        #[serde(rename = "sessionID")]
        session_id: String,
        path: String,
    },
    ReadRange {
        #[serde(rename = "sessionID")]
        session_id: String,
        path: String,
        offset: i64,
    },
    ArchiveFolder {
        #[serde(rename = "sessionID")]
        session_id: String,
        path: String,
    },
    BeginWrite {
        #[serde(rename = "sessionID")]
        session_id: String,
        path: String,
        total_bytes: i64,
    },
    WriteChunk {
        #[serde(rename = "sessionID")]
        session_id: String,
        path: String,
        #[serde(with = "base64_bytes")]
        data: Vec<u8>,
        is_last: bool,
    },
    ChangeFile {
        #[serde(rename = "sessionID")]
        session_id: String,
        operation: RemoteFileOperation,
    },
    RegisterPushToken {
        #[serde(rename = "_0", with = "base64_bytes")]
        token: Vec<u8>,
    },
}
