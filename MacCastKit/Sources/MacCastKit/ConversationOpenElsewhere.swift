import Foundation

/// Whether a conversation file was last written by someone else, so a terminal may still have it open.
public enum ConversationOpenElsewhere {
    public static let window: TimeInterval = 120
    /// The CLI flushes its last lines a moment after the process is stopped.
    public static let flushSlack: TimeInterval = 5

    /// `releasedAt` is when this app closed its own chat on the file: writes up to then are ours, not a terminal's.
    public static func isLikely(modified: Date, now: Date, releasedAt: Date?) -> Bool {
        guard now.timeIntervalSince(modified) < window else { return false }
        guard let releasedAt else { return true }
        return modified > releasedAt.addingTimeInterval(flushSlack)
    }
}
