use super::session::TerminalSessionInfo;
use crate::files::{RemoteDirectoryEntry, RemoteFileKind};
use crate::swift_enum::base64_bytes;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TerminalAttentionKind {
    Confirmation,
    Password,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum TerminalEvent {
    Snapshot {
        #[serde(rename = "_0")]
        terminals: Vec<TerminalSessionInfo>,
    },
    Agents {
        installed: Vec<String>,
    },
    Created {
        #[serde(rename = "_0")]
        terminal: TerminalSessionInfo,
    },
    Renamed {
        #[serde(rename = "_0")]
        terminal: TerminalSessionInfo,
    },
    Output {
        #[serde(rename = "sessionID")]
        session_id: String,
        #[serde(with = "base64_bytes")]
        data: Vec<u8>,
    },
    Attention {
        #[serde(rename = "sessionID")]
        session_id: String,
        kind: TerminalAttentionKind,
        message: String,
    },
    CommandFinished {
        #[serde(rename = "sessionID")]
        session_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        command: Option<String>,
        duration: f64,
        exit_status: i32,
    },
    Exited {
        #[serde(rename = "sessionID")]
        session_id: String,
        status: i32,
    },
    Closed {
        #[serde(rename = "sessionID")]
        session_id: String,
    },
    Directory {
        #[serde(rename = "sessionID")]
        session_id: String,
        path: String,
        entries: Vec<RemoteDirectoryEntry>,
        truncated: bool,
    },
    FileContents {
        #[serde(rename = "sessionID")]
        session_id: String,
        path: String,
        kind: RemoteFileKind,
        offset: i64,
        total_bytes: i64,
        #[serde(with = "base64_bytes")]
        data: Vec<u8>,
        is_last: bool,
    },
    FileRange {
        #[serde(rename = "sessionID")]
        session_id: String,
        path: String,
        offset: i64,
        total_bytes: i64,
        #[serde(with = "base64_bytes")]
        data: Vec<u8>,
    },
    ArchiveReady {
        #[serde(rename = "sessionID")]
        session_id: String,
        folder: String,
        archive_path: String,
        total_bytes: i64,
    },
    TransferFailure {
        #[serde(rename = "sessionID")]
        session_id: String,
        path: String,
        message: String,
    },
    BrowseFailure {
        #[serde(rename = "sessionID")]
        session_id: String,
        path: String,
        message: String,
    },
    WroteFile {
        #[serde(rename = "sessionID")]
        session_id: String,
        path: String,
        total_bytes: i64,
    },
    WriteFailure {
        #[serde(rename = "sessionID")]
        session_id: String,
        path: String,
        message: String,
    },
    FileOperationDone {
        #[serde(rename = "sessionID")]
        session_id: String,
        path: String,
        note: String,
    },
    FileOperationFailure {
        #[serde(rename = "sessionID")]
        session_id: String,
        path: String,
        message: String,
    },
    Failed {
        #[serde(rename = "sessionID", default, skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
        message: String,
    },
}
