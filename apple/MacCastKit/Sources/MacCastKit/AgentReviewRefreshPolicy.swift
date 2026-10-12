import Foundation

/// When to ask the Mac for a chat's changes again, so the list stays fresh without a request per redraw.
public struct AgentReviewRefreshPolicy: Equatable {
    public enum Reason: Equatable {
        case hubAppeared
        case turnFinished
    }

    public static let appearInterval: TimeInterval = 30
    /// A finished turn is the moment files change, so it asks sooner, but not twice in a burst.
    public static let turnInterval: TimeInterval = 3

    private var askedAt: [UUID: ContinuousClock.Instant] = [:]

    public init() {}

    /// The chats to ask now; they are recorded as asked.
    public mutating func chatsToAsk(_ chats: [UUID], reason: Reason, now: ContinuousClock.Instant) -> [UUID] {
        let interval = reason == .turnFinished ? Self.turnInterval : Self.appearInterval
        let due = chats.filter { chat in askedAt[chat].map { $0.duration(to: now) >= .seconds(interval) } ?? true }
        for chat in due { askedAt[chat] = now }
        return due
    }

    public mutating func forget(except live: Set<UUID>) {
        askedAt = askedAt.filter { live.contains($0.key) }
    }
}
