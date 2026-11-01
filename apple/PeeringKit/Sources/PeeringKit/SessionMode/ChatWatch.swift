import Foundation

/// Leaving a chat to watch the Mac's screen, and coming back to the same chat in the mode the session was in.
public struct ChatWatch: Equatable, Sendable {
    public let chatID: UUID
    /// The Mac being watched: a visit means nothing once another Mac is on screen.
    public let sessionID: UUID
    public let previousMode: SessionMode

    public init(chatID: UUID, sessionID: UUID, previousMode: SessionMode) {
        self.chatID = chatID
        self.sessionID = sessionID
        self.previousMode = previousMode
    }

    public func isStillWatching(activeSessionID: UUID?) -> Bool {
        activeSessionID == sessionID
    }

    /// Watching needs the picture, so every mode is left for the screen while it lasts.
    public var watchingMode: SessionMode { .screen }

    /// The mode to put back on return; nil when the session never left it.
    public var modeToRestore: SessionMode? {
        previousMode == watchingMode ? nil : previousMode
    }

    /// Offered once a turn has ended with something the agent said in it, not while it works or before it has replied.
    public static func isOffered(for transcript: AgentTranscript) -> Bool {
        guard transcript.state == .idle else { return false }
        let turn = transcript.items.reversed().prefix { if case .user = $0 { return false } else { return true } }
        return turn.contains { if case .reply = $0 { return true } else { return false } }
    }
}
