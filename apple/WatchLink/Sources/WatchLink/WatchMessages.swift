import Foundation

/// Everything the phone has waiting, replacing what the watch had. A snapshot rather than a stream of changes: a missed message then costs nothing, because the next one says it all.
public struct WatchApprovalSnapshot: Codable, Equatable, Sendable {
    public static let contextKey = "approvals"

    public let approvals: [WatchApproval]
    public let sentAt: Date

    public init(approvals: [WatchApproval], sentAt: Date) {
        self.approvals = approvals
        self.sentAt = sentAt
    }

    public var context: [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return [Self.contextKey: data]
    }

    public init?(context: [String: Any]) {
        guard let data = context[Self.contextKey] as? Data,
              let decoded = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        self = decoded
    }
}

/// A button pressed on the watch. Carries what the phone needs to answer without looking the question up, since the phone may have been woken for nothing else.
public struct WatchAnswer: Codable, Equatable, Sendable {
    public static let messageKey = "answer"

    public let approvalID: String
    public let sessionID: UUID
    public let hostID: String?
    public let actionIdentifier: String
    public let answers: [String]

    public init(approvalID: String, sessionID: UUID, hostID: String?, actionIdentifier: String, answers: [String]) {
        self.approvalID = approvalID
        self.sessionID = sessionID
        self.hostID = hostID
        self.actionIdentifier = actionIdentifier
        self.answers = answers
    }

    public var message: [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return [Self.messageKey: data]
    }

    public init?(message: [String: Any]) {
        guard let data = message[Self.messageKey] as? Data,
              let decoded = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        self = decoded
    }
}

/// The phone's reply to a ``WatchAnswer``: whether the Mac confirmed it.
public enum WatchAnswerReply {
    public static let deliveredKey = "delivered"

    public static func payload(delivered: Bool) -> [String: Any] { [deliveredKey: delivered] }

    public static func isDelivered(_ reply: [String: Any]) -> Bool { reply[deliveredKey] as? Bool ?? false }
}
