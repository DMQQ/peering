import Foundation

/// One question an agent is waiting on, as much of it as a wrist shows.
public struct WatchApproval: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A tool wants to run: allow or deny.
        case allowDeny
        /// One question with a few answers, each its own button.
        case options
        /// A plan or several questions: only the phone can answer.
        case openOnly
    }

    /// A button on the watch and the identifier it sends back. The identifiers are the ones the phone's notification buttons use, so one decision table serves both.
    public struct Choice: Equatable, Sendable, Identifiable {
        public let actionIdentifier: String
        public let label: String
        public var id: String { actionIdentifier }
    }

    public static let allowIdentifier = "allow"
    public static let denyIdentifier = "deny"
    public static let optionPrefix = "choose."

    public var id: String { approvalID }
    public let approvalID: String
    public let sessionID: UUID
    public let hostID: String?
    public let chatTitle: String
    public let hostName: String?
    public let body: String
    public let kind: Kind
    /// Full labels of a question's options, in button order.
    public let answers: [String]
    public let postedAt: Date

    public init(
        approvalID: String,
        sessionID: UUID,
        hostID: String?,
        chatTitle: String,
        hostName: String?,
        body: String,
        kind: Kind,
        answers: [String] = [],
        postedAt: Date
    ) {
        self.approvalID = approvalID
        self.sessionID = sessionID
        self.hostID = hostID
        self.chatTitle = chatTitle
        self.hostName = hostName
        self.body = body
        self.kind = kind
        self.answers = answers
        self.postedAt = postedAt
    }

    /// The buttons to draw, with the destructive one first so it is not the one under the thumb.
    public func choices(allowTitle: String, denyTitle: String) -> [Choice] {
        switch kind {
        case .allowDeny:
            [Choice(actionIdentifier: Self.denyIdentifier, label: denyTitle), Choice(actionIdentifier: Self.allowIdentifier, label: allowTitle)]
        case .options:
            answers.enumerated().map { Choice(actionIdentifier: Self.optionPrefix + String($0.offset), label: $0.element) }
        case .openOnly:
            []
        }
    }

    /// The same question with another time on it: the phone stamps the moment it first saw a question, so republishing it does not look like a change.
    public func posted(at moment: Date) -> WatchApproval {
        WatchApproval(approvalID: approvalID, sessionID: sessionID, hostID: hostID, chatTitle: chatTitle, hostName: hostName, body: body, kind: kind, answers: answers, postedAt: moment)
    }

    public func answer(_ choice: Choice) -> WatchAnswer {
        WatchAnswer(approvalID: approvalID, sessionID: sessionID, hostID: hostID, actionIdentifier: choice.actionIdentifier, answers: answers)
    }
}
