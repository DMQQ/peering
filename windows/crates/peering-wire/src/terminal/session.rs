use serde::{Deserialize, Serialize};

/// A terminal as the Mac lists it. `id` is an uppercase UUID string; `created_at` is seconds since 2001-01-01.
///
/// `columns`, `rows` and `created_at` are absent from a Mac too old to send them.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalSessionInfo {
    pub id: String,
    pub name: String,
    pub is_running: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub columns: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rows: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_at: Option<f64>,
}
