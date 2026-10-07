import Foundation
import RemoteCore

/// What a notification for an agent's approval request offers, worked out without UserNotifications so it can be tested.
public struct AgentApprovalNotification: Equatable, Sendable {
    public enum Layout: Equatable, Sendable {
        /// A tool wants to run: allow or deny.
        case allowDeny
        /// One question with a few answers, each its own button.
        case options([String])
        /// Several questions, a plan, or more answers than a notification can hold: only the app can answer.
        case openOnly
    }

    public struct Action: Equatable, Sendable {
        public enum Title: Equatable, Sendable {
            case allow
            case deny
            case open
            case option(String)
        }

        public let identifier: String
        public let title: Title
        /// A locked phone must not approve by one tap.
        public let requiresAuthentication: Bool
        /// Opens the app instead of answering in the background.
        public let opensApp: Bool
    }

    /// The most answers shown as buttons: a banner lists about four before it needs a scroll.
    public static let maxOptionActions = 4
    public static let maxOptionTitleLength = 40
    public static let maxBodyLength = 240

    public static let allowIdentifier = "allow"
    public static let denyIdentifier = "deny"
    public static let openIdentifier = "open"
    static let optionPrefix = "choose."

    public static let identifierPrefix = "peering-agent-approval-"
    public static let toolCategory = "peering.agent.approval.tool"
    public static let openCategory = "peering.agent.approval.open"
    static let optionsCategoryPrefix = "peering.agent.approval.options."

    public let approvalID: String
    public let sessionID: UUID
    public let layout: Layout
    /// The reason or the command asked about, cut to what a lock screen shows.
    public let body: String
    public let isQuestion: Bool
    public let isPlan: Bool

    public init(approval: AgentApproval, sessionID: UUID) {
        approvalID = approval.id
        self.sessionID = sessionID
        let call = approval.call
        isQuestion = !(call.questions ?? []).isEmpty
        isPlan = call.name == "ExitPlanMode"
        body = Self.truncated(AgentApprovalBody.text(command: call.detail, reason: approval.reason) ?? "")
        layout = Self.layout(for: call)
    }

    static func layout(for call: AgentToolCall) -> Layout {
        let questions = call.questions ?? []
        if call.name == "ExitPlanMode" || questions.count > 1 { return .openOnly }
        guard questions.count == 1 else { return .allowDeny }
        let labels = questions[0].options.map(\.label).filter { !$0.isEmpty }
        return (1...maxOptionActions).contains(labels.count) ? .options(labels) : .openOnly
    }

    /// The category a push can name: a push cannot carry per-question button titles, so a question gets Open.
    public static func pushCategory(for call: AgentToolCall) -> String {
        layout(for: call) == .allowDeny ? toolCategory : openCategory
    }

    public var identifier: String { Self.identifierPrefix + approvalID }

    public static func isApprovalIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(identifierPrefix)
    }

    public var categoryIdentifier: String { Self.categoryIdentifier(forLayout: layout, approvalID: approvalID) }

    public static func categoryIdentifier(forLayout layout: Layout, approvalID: String) -> String {
        switch layout {
        case .allowDeny: toolCategory
        case .openOnly: openCategory
        case .options: optionsCategoryPrefix + approvalID
        }
    }

    public var actions: [Action] { Self.actions(for: layout) }

    public static func actions(for layout: Layout) -> [Action] {
        switch layout {
        case .allowDeny:
            [
                Action(identifier: denyIdentifier, title: .deny, requiresAuthentication: false, opensApp: false),
                Action(identifier: allowIdentifier, title: .allow, requiresAuthentication: true, opensApp: false),
            ]
        case .options(let labels):
            labels.enumerated().map { index, label in
                Action(identifier: optionPrefix + String(index), title: .option(shortened(label)), requiresAuthentication: false, opensApp: false)
            }
        case .openOnly:
            [Action(identifier: openIdentifier, title: .open, requiresAuthentication: false, opensApp: true)]
        }
    }

    /// The answer a tapped button stands for, or nil for Open and for anything unrecognised: those are not answers.
    /// `answers` are the full labels, since a button's title may have been shortened.
    public static func decision(forActionIdentifier identifier: String, answers: [String]) -> AgentApprovalDecision? {
        switch identifier {
        case allowIdentifier:
            return .allow
        case denyIdentifier:
            return .deny
        default:
            guard identifier.hasPrefix(optionPrefix),
                  let index = Int(identifier.dropFirst(optionPrefix.count)),
                  answers.indices.contains(index)
            else { return nil }
            return .choose([answers[index]])
        }
    }

    // MARK: - Payload

    public enum UserInfoKey {
        public static let approvalID = "agentApprovalId"
        public static let sessionID = "agentSessionId"
        public static let hostID = "hostId"
        public static let answers = "agentAnswers"
    }

    /// Rides in `userInfo`, so a response delivered to a freshly launched process is self-contained.
    /// `answers` are the full labels of a question's options (empty otherwise).
    public func userInfo(hostID: String?, answers: [String]) -> [String: Any] {
        Reference.userInfo(for: Reference(approvalID: approvalID, sessionID: sessionID, hostID: hostID, answers: answers))
    }

    public struct Reference: Equatable, Sendable {
        public let approvalID: String
        public let sessionID: UUID
        public let hostID: String?
        public let answers: [String]

        public init?(userInfo: [AnyHashable: Any]) {
            guard let approvalID = userInfo[UserInfoKey.approvalID] as? String,
                  let session = (userInfo[UserInfoKey.sessionID] as? String).flatMap(UUID.init(uuidString:))
            else { return nil }
            self.approvalID = approvalID
            sessionID = session
            hostID = userInfo[UserInfoKey.hostID] as? String
            answers = userInfo[UserInfoKey.answers] as? [String] ?? []
        }

        public init(approvalID: String, sessionID: UUID, hostID: String?, answers: [String] = []) {
            self.approvalID = approvalID
            self.sessionID = sessionID
            self.hostID = hostID
            self.answers = answers
        }

        /// The same payload as the notification it refers to.
        public static func userInfo(for reference: Reference) -> [String: Any] {
            var info: [String: Any] = [
                UserInfoKey.approvalID: reference.approvalID,
                UserInfoKey.sessionID: reference.sessionID.uuidString,
            ]
            if let hostID = reference.hostID { info[UserInfoKey.hostID] = hostID }
            if !reference.answers.isEmpty { info[UserInfoKey.answers] = reference.answers }
            return info
        }

        /// What the category was when it was posted, rebuilt for a notification still on the lock screen after a relaunch.
        public var layoutForCategory: Layout {
            answers.isEmpty ? .allowDeny : .options(answers)
        }
    }

    /// The answers a question offers, full length, in the order their buttons appear.
    public var answers: [String] {
        guard case .options(let labels) = layout else { return [] }
        return labels
    }

    // MARK: - Text

    public static func truncated(_ text: String, limit: Int = maxBodyLength) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let cut = trimmed.prefix(max(limit - 1, 0)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cut + "\u{2026}"
    }

    static func shortened(_ label: String) -> String {
        truncated(label, limit: maxOptionTitleLength)
    }
}
