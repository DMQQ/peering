//! The review of a chat's folder and the result of a commit or push. Mirrors `AgentChanges.swift` and
//! `AgentGitResult.swift` in RemoteCore. Swift omits a nil optional, so every `Option` is skipped when empty.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AgentChangeKind {
    Modified,
    Added,
    Deleted,
    Untracked,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentChangedFile {
    /// Relative to the session's folder, with `/` separators.
    pub path: String,
    pub kind: AgentChangeKind,
    pub added: i64,
    pub removed: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diff: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentGitBranch {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upstream: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub merge_ref: Option<String>,
    pub ahead: i64,
    pub behind: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentChangesReport {
    pub is_repository: bool,
    pub files: Vec<AgentChangedFile>,
    pub paths: Vec<String>,
    pub truncated: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<AgentGitBranch>,
}

impl AgentChangesReport {
    pub fn failure(message: &str) -> Self {
        Self { is_repository: false, files: Vec::new(), paths: Vec::new(), truncated: false, message: Some(message.to_owned()), branch: None }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AgentGitOperation {
    Commit,
    Push,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentGitResult {
    pub operation: AgentGitOperation,
    pub succeeded: bool,
    pub message: String,
}

/// Whether a path git reported stays inside the folder it was asked about: relative, with no `..` and no empty or
/// NUL-bearing component.
pub fn is_inside_folder(path: &str) -> bool {
    if path.is_empty() || path.starts_with('/') || path.contains('\0') {
        return false;
    }
    !path.split('/').any(|part| part == ".." || part.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::tests::assert_wire;

    #[test]
    fn a_full_report_matches_the_swift_encoding() {
        assert_wire::<AgentChangesReport>(
            r#"{"isRepository":true,"files":[{"path":"a b.txt","kind":"untracked","added":1,"removed":0,"diff":"+x"},{"path":"img.png","kind":"modified","added":0,"removed":0}],"paths":["a b.txt","img.png"],"truncated":false,"branch":{"head":"main","upstream":"origin/main","remote":"origin","mergeRef":"refs/heads/main","ahead":2,"behind":0}}"#,
        );
    }

    #[test]
    fn a_failure_report_carries_its_message_and_no_branch() {
        let json = serde_json::to_string(&AgentChangesReport::failure("no git")).expect("encodes");
        assert_eq!(json, r#"{"isRepository":false,"files":[],"paths":[],"truncated":false,"message":"no git"}"#);
    }

    #[test]
    fn a_detached_branch_omits_its_head() {
        assert_wire::<AgentGitBranch>(r#"{"ahead":0,"behind":0}"#);
    }

    #[test]
    fn a_git_result_matches_the_swift_encoding() {
        assert_wire::<AgentGitResult>(r#"{"operation":"push","succeeded":false,"message":"no"}"#);
    }

    #[test]
    fn paths_that_leave_the_folder_are_not_inside_it() {
        assert!(is_inside_folder("src/main.rs"));
        for bad in ["", "/etc/passwd", "../x", "a/../b", "a//b", "a/", "a\0b"] {
            assert!(!is_inside_folder(bad), "{bad:?}");
        }
    }
}
