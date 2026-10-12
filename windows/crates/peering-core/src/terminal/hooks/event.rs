//! One line a Claude Code hook sent, read into what the broker needs.

use serde_json::Value;

/// Tools whose ask is a question or a plan: a bare Allow would approve them with nothing chosen.
const TOOLS_NEEDING_THE_APP: [&str; 2] = ["AskUserQuestion", "ExitPlanMode"];
const DETAIL_KEYS: [&str; 7] = ["command", "file_path", "path", "pattern", "url", "query", "description"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HookKind {
    PermissionRequest,
    Notification,
    Other(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookEvent {
    pub kind: HookKind,
    pub session_id: String,
    pub directory: Option<String>,
    pub tool_name: Option<String>,
    /// The command or path the tool wants to act on, as a lock screen can show it.
    pub detail: Option<String>,
    pub message: Option<String>,
}

impl HookEvent {
    /// `None` for a line that is not JSON or names no event or session.
    pub fn parse(line: &[u8]) -> Option<Self> {
        let object: Value = serde_json::from_slice(line).ok()?;
        let name = object.get("hook_event_name")?.as_str()?;
        let session_id = object.get("session_id")?.as_str().filter(|id| !id.is_empty())?;
        let text = |key: &str| object.get(key).and_then(Value::as_str).map(str::to_owned);
        Some(Self {
            kind: match name {
                "PermissionRequest" => HookKind::PermissionRequest,
                "Notification" => HookKind::Notification,
                other => HookKind::Other(other.to_owned()),
            },
            session_id: session_id.to_owned(),
            directory: text("cwd"),
            tool_name: text("tool_name"),
            detail: object.get("tool_input").and_then(detail_of),
            message: text("message"),
        })
    }

    /// The folder's name, which is what tells two terminals apart.
    pub fn project_name(&self) -> Option<String> {
        let directory = self.directory.as_deref()?;
        let name = directory.trim_end_matches(['/', '\\']).rsplit(['/', '\\']).next()?;
        (!name.is_empty()).then(|| name.to_owned())
    }

    /// Whether Allow on a lock screen may answer this: a question and a plan are the app's to answer.
    pub fn can_be_answered_from_a_notification(&self) -> bool {
        self.kind == HookKind::PermissionRequest
            && self.tool_name.as_deref().is_some_and(|tool| !TOOLS_NEEDING_THE_APP.contains(&tool))
    }
}

fn detail_of(input: &Value) -> Option<String> {
    DETAIL_KEYS
        .iter()
        .find_map(|key| input.get(key).and_then(Value::as_str).filter(|text| !text.is_empty()))
        .map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(json: &str) -> Option<HookEvent> {
        HookEvent::parse(json.as_bytes())
    }

    #[test]
    fn a_bash_permission_request_carries_its_command_and_folder() {
        let event = parse(
            r#"{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/Users/x/code/app",
                "tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#,
        )
        .expect("a valid line");
        assert_eq!(event.kind, HookKind::PermissionRequest);
        assert_eq!(event.detail.as_deref(), Some("rm -rf build"));
        assert_eq!(event.project_name().as_deref(), Some("app"));
        assert!(event.can_be_answered_from_a_notification());
    }

    #[test]
    fn a_windows_folder_names_its_project_too() {
        let event = parse(r#"{"hook_event_name":"Stop","session_id":"s","cwd":"C:\\Users\\me\\code\\app\\"}"#).expect("valid");
        assert_eq!(event.project_name().as_deref(), Some("app"));
        assert_eq!(event.kind, HookKind::Other("Stop".to_owned()));
    }

    #[test]
    fn a_file_tool_shows_its_path() {
        let event = parse(
            r#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Edit",
                "tool_input":{"file_path":"/a/b.swift","old_string":"x"}}"#,
        )
        .expect("a valid line");
        assert_eq!(event.detail.as_deref(), Some("/a/b.swift"));
    }

    #[test]
    fn a_question_is_left_to_the_app() {
        let event = parse(
            r#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"AskUserQuestion","tool_input":{}}"#,
        )
        .expect("a valid line");
        assert!(!event.can_be_answered_from_a_notification());
    }

    #[test]
    fn a_notification_is_not_an_approval() {
        let event = parse(r#"{"hook_event_name":"Notification","session_id":"s1","message":"Claude is waiting for your input"}"#)
            .expect("a valid line");
        assert_eq!(event.kind, HookKind::Notification);
        assert_eq!(event.message.as_deref(), Some("Claude is waiting for your input"));
        assert!(!event.can_be_answered_from_a_notification());
    }

    #[test]
    fn a_line_without_a_session_is_refused() {
        assert_eq!(parse(r#"{"hook_event_name":"Stop"}"#), None);
        assert_eq!(parse(r#"{"hook_event_name":"Stop","session_id":""}"#), None);
        assert_eq!(parse("not json"), None);
        assert_eq!(parse("[1]"), None);
    }
}
