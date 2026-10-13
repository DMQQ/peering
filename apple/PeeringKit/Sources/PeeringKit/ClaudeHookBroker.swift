import Foundation
import RemoteCore

/// Turns a Claude Code hook into a notification on the phone and, for a permission request, holds the hook until the phone answers.
public final class ClaudeHookBroker: @unchecked Sendable {
    public typealias Reply = @Sendable (Data?) -> Void
    public typealias Push = @Sendable (_ token: String, _ title: String, _ body: String, _ action: RelayPushAction?) -> Void
    public typealias Schedule = @Sendable (_ seconds: Int, _ work: @escaping @Sendable () -> Void) -> Void

    /// Short of the hook's own timeout, so the answer to a request nobody took is Claude Code's dialog and not a killed hook.
    public static let holdSeconds = ClaudeHookSettings.permissionTimeoutSeconds - 10

    private let tokens: @Sendable () -> [String]
    private let push: Push
    private let schedule: Schedule
    private let words: AgentNotificationWords

    private let lock = NSLock()
    /// Guarded by `lock`.
    private var held: [String: Reply] = [:]

    public init(
        tokens: @escaping @Sendable () -> [String],
        push: @escaping Push,
        schedule: @escaping Schedule = { seconds, work in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
        },
        words: AgentNotificationWords = .english
    ) {
        self.words = words
        self.tokens = tokens
        self.push = push
        self.schedule = schedule
    }

    public func handle(_ event: ClaudeHookEvent, reply: @escaping Reply) {
        let devices = tokens()
        switch event.kind {
        case .permissionRequest:
            permissionRequest(event, devices: devices, reply: reply)
        case .notification:
            let body = event.message ?? words.claudeCodeWaiting
            for token in devices { push(token, title(for: event), body, nil) }
            reply(nil)
        case .other:
            reply(nil)
        }
    }

    /// True when `approvalID` was a held hook, which is then answered.
    public func resolve(approvalID: String, decision: AgentApprovalDecision) -> Bool {
        let reply = lock.withLock { held.removeValue(forKey: approvalID) }
        guard let reply else { return false }
        switch decision {
        case .allow: reply(ClaudeHookReply.permission(.allow))
        case .deny: reply(ClaudeHookReply.permission(.deny))
        case .choose: reply(nil)
        }
        return true
    }

    // MARK: - Permission requests

    private func permissionRequest(_ event: ClaudeHookEvent, devices: [String], reply: @escaping Reply) {
        guard !devices.isEmpty else {
            reply(nil)
            return
        }
        let approvalID = UUID().uuidString
        let call = AgentToolCall(id: approvalID, name: event.toolName ?? "", title: event.toolName ?? "", detail: event.detail)
        let category = AgentApprovalNotification.pushCategory(for: call)
        let holds = event.canBeAnsweredFromANotification && category == AgentApprovalNotification.toolCategory

        let text = AgentNotificationText.approval(agentName: title(for: event), reason: nil, detail: event.detail, words: words)
        let action = RelayPushAction(
            category: category,
            sessionID: (UUID(uuidString: event.sessionID) ?? UUID()).uuidString,
            approvalID: approvalID
        )
        if holds { hold(approvalID, reply: reply) } else { reply(nil) }
        for token in devices { push(token, text.title, text.body, action) }
    }

    private func hold(_ approvalID: String, reply: @escaping Reply) {
        lock.withLock { held[approvalID] = reply }
        schedule(Self.holdSeconds) { [weak self] in
            let expired = self?.lock.withLock { self?.held.removeValue(forKey: approvalID) }
            expired?(nil)
        }
    }

    private func title(for event: ClaudeHookEvent) -> String {
        event.projectName.map(words.claudeCodeIn) ?? words.claudeCode
    }
}
