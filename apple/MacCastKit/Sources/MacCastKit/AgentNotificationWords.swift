import Foundation

/// The sentences of an agent push, supplied by the caller. A Swift package gets no strings
/// extracted by Xcode, so the app builds a localized set and this package keeps English as the
/// default for tests and for any caller that has none.
public struct AgentNotificationWords: Sendable {
    public enum Outcome: Sendable, Equatable {
        case finished, stopped, failed
    }

    public var asks: @Sendable (_ agentName: String) -> String
    public var needsApproval: String
    public var title: @Sendable (_ agentName: String, _ outcome: Outcome) -> String
    public var turn: @Sendable (_ outcome: Outcome) -> String
    public var filesChanged: @Sendable (_ count: Int) -> String
    public var duration: @Sendable (_ seconds: TimeInterval) -> String
    public var claudeCode: String
    public var claudeCodeIn: @Sendable (_ project: String) -> String
    public var claudeCodeWaiting: String

    public init(
        asks: @escaping @Sendable (String) -> String,
        needsApproval: String,
        title: @escaping @Sendable (String, Outcome) -> String,
        turn: @escaping @Sendable (Outcome) -> String,
        filesChanged: @escaping @Sendable (Int) -> String,
        duration: @escaping @Sendable (TimeInterval) -> String,
        claudeCode: String,
        claudeCodeIn: @escaping @Sendable (String) -> String,
        claudeCodeWaiting: String
    ) {
        self.asks = asks
        self.needsApproval = needsApproval
        self.title = title
        self.turn = turn
        self.filesChanged = filesChanged
        self.duration = duration
        self.claudeCode = claudeCode
        self.claudeCodeIn = claudeCodeIn
        self.claudeCodeWaiting = claudeCodeWaiting
    }

    public static let english = AgentNotificationWords(
        asks: { "\($0) asks" },
        needsApproval: "Needs your approval.",
        title: { name, outcome in
            switch outcome {
            case .finished: "\(name) finished"
            case .stopped: "\(name) stopped"
            case .failed: "\(name) failed"
            }
        },
        turn: { outcome in
            switch outcome {
            case .finished: "The turn finished."
            case .stopped: "The turn was stopped."
            case .failed: "The turn failed."
            }
        },
        filesChanged: { $0 == 1 ? "1 file changed" : "\($0) files changed" },
        duration: { AgentTurnFormat.duration($0) },
        claudeCode: "Claude Code",
        claudeCodeIn: { "Claude Code in \($0)" },
        claudeCodeWaiting: "Claude Code is waiting for you."
    )
}
