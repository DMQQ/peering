import Foundation

/// One line a Claude Code hook sent to the Mac, read without AppKit so it can be tested.
public struct ClaudeHookEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case permissionRequest
        case notification
        case other(String)
    }

    /// Tools whose ask is a question or a plan: a bare Allow would approve them with nothing chosen.
    static let toolsNeedingTheApp: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    public let kind: Kind
    public let sessionID: String
    public let directory: String?
    public let toolName: String?
    /// The command or path the tool wants to act on, as a lock screen can show it.
    public let detail: String?
    public let message: String?
    /// What kind of notification a `Notification` hook is, such as `idle_prompt`, when Claude Code says.
    public let notificationType: String?

    /// The folder's name, which is what tells two terminals apart.
    public init(kind: Kind, sessionID: String, directory: String?, toolName: String?, detail: String?, message: String?, notificationType: String? = nil) {
        self.kind = kind
        self.sessionID = sessionID
        self.directory = directory
        self.toolName = toolName
        self.detail = detail
        self.message = message
        self.notificationType = notificationType
    }

    public var projectName: String? {
        directory.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether Allow on a lock screen may answer this: a question, a plan and a command too long to read are the app's to answer.
    public var canBeAnsweredFromANotification: Bool {
        guard kind == .permissionRequest, let toolName else { return false }
        return !Self.toolsNeedingTheApp.contains(toolName)
    }

    public static func parse(_ line: Data) -> ClaudeHookEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let name = object["hook_event_name"] as? String,
              let sessionID = object["session_id"] as? String, !sessionID.isEmpty
        else { return nil }

        let toolName = object["tool_name"] as? String
        let input = object["tool_input"] as? [String: Any] ?? [:]
        return ClaudeHookEvent(
            kind: kind(named: name),
            sessionID: sessionID,
            directory: object["cwd"] as? String,
            toolName: toolName,
            detail: detail(of: input),
            message: object["message"] as? String,
            notificationType: object["notification_type"] as? String
        )
    }

    private static func kind(named name: String) -> Kind {
        switch name {
        case "PermissionRequest": .permissionRequest
        case "Notification": .notification
        default: .other(name)
        }
    }

    private static func detail(of input: [String: Any]) -> String? {
        for key in ["command", "file_path", "path", "pattern", "url", "query", "description"] {
            if let text = input[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }
}
