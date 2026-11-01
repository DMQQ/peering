import Foundation
import RemoteCore

/// One chat on the board of every chat across every connected Mac.
public struct ChatBoardEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// The phone's session with the Mac the chat runs on, not the Mac's own ID.
    public let macSessionID: UUID
    public let macName: String
    public let agentID: String
    public let title: String
    public let snippet: String?
    public let state: AgentSessionState
    public let isPaused: Bool
    public let changedAt: Date
    public let isUnread: Bool

    public init(
        id: UUID,
        macSessionID: UUID,
        macName: String,
        agentID: String,
        title: String,
        snippet: String?,
        state: AgentSessionState,
        isPaused: Bool,
        changedAt: Date,
        isUnread: Bool
    ) {
        self.id = id
        self.macSessionID = macSessionID
        self.macName = macName
        self.agentID = agentID
        self.title = title
        self.snippet = snippet
        self.state = state
        self.isPaused = isPaused
        self.changedAt = changedAt
        self.isUnread = isUnread
    }

    public var group: ChatBoardGroup {
        if isPaused { return .done }
        switch state {
        case .awaitingApproval: return .needsYou
        case .working: return .working
        case .idle, .exited, .failed: return .done
        }
    }
}

public enum ChatBoardGroup: Int, CaseIterable, Sendable, Comparable {
    case needsYou
    case working
    case done

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
