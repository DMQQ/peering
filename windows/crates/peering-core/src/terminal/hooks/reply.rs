//! What a `PermissionRequest` hook prints to answer the permission dialog before the terminal shows it.

use serde_json::json;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookDecision {
    Allow,
    Deny,
}

/// One JSON line. Printing nothing at all lets Claude Code show its own dialog, which is the safe answer to anything unclear.
pub fn permission_reply(decision: HookDecision) -> Vec<u8> {
    let verdict = match decision {
        HookDecision::Allow => json!({ "behavior": "allow" }),
        HookDecision::Deny => json!({ "behavior": "deny", "message": "Denied from the Peering notification." }),
    };
    let object = json!({ "hookSpecificOutput": { "hookEventName": "PermissionRequest", "decision": verdict } });
    let mut line = serde_json::to_vec(&object).unwrap_or_default();
    line.push(b'\n');
    line
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn decision_of(decision: HookDecision) -> (Value, Value) {
        let object: Value = serde_json::from_slice(&permission_reply(decision)).expect("a JSON line");
        let output = object["hookSpecificOutput"].clone();
        (output["hookEventName"].clone(), output["decision"].clone())
    }

    #[test]
    fn an_allow_reply_names_the_event_and_the_behaviour() {
        let (event, decision) = decision_of(HookDecision::Allow);
        assert_eq!(event, "PermissionRequest");
        assert_eq!(decision["behavior"], "allow");
    }

    #[test]
    fn a_deny_reply_says_why() {
        let (_, decision) = decision_of(HookDecision::Deny);
        assert_eq!(decision["behavior"], "deny");
        assert!(decision["message"].is_string());
    }

    #[test]
    fn a_reply_is_one_line() {
        let line = permission_reply(HookDecision::Allow);
        assert_eq!(line.iter().filter(|&&byte| byte == b'\n').count(), 1);
        assert_eq!(line.last(), Some(&b'\n'));
    }
}
