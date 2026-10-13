import Foundation

/// Adds and removes Peering's entries in Claude Code's `settings.json`, leaving every other key and every other hook as it was.
public enum ClaudeHookSettings {
    public enum Failure: Error, Equatable {
        /// A shape this does not know is refused, never replaced: the file is the user's.
        case unexpectedShape(String)
    }

    /// How long a held permission request waits for the phone, in seconds, before Claude Code shows its own dialog. Ten minutes: a phone in a pocket is slow, and the terminal prompt is still there after.
    public static let permissionTimeoutSeconds = 600
    static let notificationTimeoutSeconds = 10
    /// Question notifications only: a permission prompt already reaches the phone as a `PermissionRequest`, and the end of a turn is the `Stop` hook. An `idle_prompt` fires after a quiet minute whether or not Claude is still working, so it is no evidence of anything.
    static let notificationMatcher = "elicitation_dialog"

    /// The name every Peering entry's command ends in, which is how an entry is recognised later.
    public static let commandName = "peering-hook"

    public static func installing(command: String, into settings: [String: Any]) throws -> [String: Any] {
        var settings = try removing(from: settings)
        var hooks = try hooks(in: settings)
        try append(to: &hooks, event: "PermissionRequest", matcher: nil, command: command, timeout: permissionTimeoutSeconds)
        try append(to: &hooks, event: "Notification", matcher: notificationMatcher, command: command, timeout: notificationTimeoutSeconds)
        try append(to: &hooks, event: "Stop", matcher: nil, command: command, timeout: notificationTimeoutSeconds)
        settings["hooks"] = hooks
        return settings
    }

    public static func removing(from settings: [String: Any]) throws -> [String: Any] {
        guard settings["hooks"] != nil else { return settings }
        var settings = settings
        var hooks = try hooks(in: settings)
        for event in hooks.keys {
            var groups = try groups(in: hooks, event: event)
            groups = groups.compactMap { group in
                guard var entries = group["hooks"] as? [[String: Any]] else { return group }
                entries.removeAll(where: isPeering)
                guard !entries.isEmpty else { return nil }
                var kept = group
                kept["hooks"] = entries
                return kept
            }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    public static func isInstalled(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return ["PermissionRequest", "Notification", "Stop"].allSatisfy { event in
            (hooks[event] as? [[String: Any]])?.contains {
                ($0["hooks"] as? [[String: Any]])?.contains(where: isPeering) == true
            } == true
        }
    }

    /// The command is quoted (the folder has a space in it), so it ends in the name and a closing quote.
    private static func isPeering(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains("/" + commandName) == true
    }

    private static func hooks(in settings: [String: Any]) throws -> [String: Any] {
        guard let raw = settings["hooks"] else { return [:] }
        guard let hooks = raw as? [String: Any] else { throw Failure.unexpectedShape("hooks") }
        return hooks
    }

    private static func groups(in hooks: [String: Any], event: String) throws -> [[String: Any]] {
        guard let raw = hooks[event] else { return [] }
        guard let groups = raw as? [[String: Any]] else { throw Failure.unexpectedShape("hooks.\(event)") }
        return groups
    }

    private static func append(
        to hooks: inout [String: Any], event: String, matcher: String?, command: String, timeout: Int
    ) throws {
        var existing = try groups(in: hooks, event: event)
        var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": timeout] as [String: Any]]]
        if let matcher { group["matcher"] = matcher }
        existing.append(group)
        hooks[event] = existing
    }
}
