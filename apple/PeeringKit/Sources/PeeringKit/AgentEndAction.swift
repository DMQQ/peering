import Foundation

/// What ending a chat does. A chat with a conversation is moved to history, not deleted, so closing it never loses what was said.
public enum AgentEndAction: Equatable, Sendable {
    case pause
    case close

    /// A working chat cannot be paused (the Mac refuses until the turn stops), and a chat nothing was said in has nothing worth keeping.
    public static func choose(hasConversation: Bool, isWorking: Bool, isPaused: Bool, hostSupportsPause: Bool) -> AgentEndAction {
        guard hostSupportsPause, hasConversation, !isWorking, !isPaused else { return .close }
        return .pause
    }
}
