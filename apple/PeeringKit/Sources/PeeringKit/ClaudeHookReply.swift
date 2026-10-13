import Foundation

/// What a `PermissionRequest` hook prints to answer the permission dialog before the terminal shows it.
public enum ClaudeHookReply {
    /// Nothing at all lets Claude Code show its own dialog, which is the safe answer to anything unclear.
    public static func permission(_ decision: ClaudeHookDecision) -> Data {
        var verdict: [String: Any]
        switch decision {
        case .allow:
            verdict = ["behavior": "allow"]
        case .deny:
            verdict = ["behavior": "deny", "message": "Denied from the Peering notification."]
        }
        let object: [String: Any] = [
            "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": verdict]
        ]
        let encoded = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return encoded + Data("\n".utf8)
    }
}

public enum ClaudeHookDecision: Equatable, Sendable {
    case allow
    case deny
}
