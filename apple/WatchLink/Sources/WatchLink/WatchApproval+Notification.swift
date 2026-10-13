import Foundation

extension WatchApproval {
    /// The notification categories the phone posts approvals under and the keys it puts in `userInfo`. Repeated here because the watch cannot link the phone's policy package; a test in that package compares them with the originals.
    public enum NotificationShape {
        public static let identifierPrefix = "peering-agent-approval-"
        public static let categoryPrefix = "peering.agent.approval."
        public static let toolCategory = "peering.agent.approval.tool"
        public static let yesNoCategory = "peering.agent.approval.yesno"
        public static let approvalIDKey = "agentApprovalId"
        public static let sessionIDKey = "agentSessionId"
        public static let hostIDKey = "hostId"
        public static let answersKey = "agentAnswers"
    }

    /// A question the phone mirrored to the watch as a notification, for when the phone is asleep and has told the watch nothing else. Nil for anything that is not an approval.
    public init?(notificationIdentifier: String, category: String, title: String, subtitle: String, body: String, userInfo: [AnyHashable: Any], date: Date) {
        typealias Keys = NotificationShape
        guard notificationIdentifier.hasPrefix(Keys.identifierPrefix),
              category.hasPrefix(Keys.categoryPrefix),
              let approvalID = userInfo[Keys.approvalIDKey] as? String,
              let sessionID = (userInfo[Keys.sessionIDKey] as? String).flatMap(UUID.init(uuidString:))
        else { return nil }
        let answers = userInfo[Keys.answersKey] as? [String] ?? []
        let kind: Kind
        var shownAnswers = answers
        switch category {
        case Keys.toolCategory:
            kind = .allowDeny
        case Keys.yesNoCategory:
            kind = .options
            shownAnswers = ["Yes", "No"]
        default:
            kind = answers.isEmpty ? .openOnly : .options
        }
        self.init(
            approvalID: approvalID,
            sessionID: sessionID,
            hostID: userInfo[Keys.hostIDKey] as? String,
            chatTitle: title,
            hostName: subtitle.isEmpty ? nil : subtitle,
            body: body,
            kind: kind,
            answers: shownAnswers,
            postedAt: date
        )
    }
}
