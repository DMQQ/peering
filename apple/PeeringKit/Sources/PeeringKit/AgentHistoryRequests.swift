import Foundation

/// Which chats the phone has already asked the Mac to replay, so each is asked for once.
public struct AgentHistoryRequests: Equatable, Sendable {
    private var asked: Set<UUID> = []

    public init() {}

    /// True when the caller should send the request now. Nothing is recorded while the wire is down, because a request sent into it is lost and would never be repeated.
    public mutating func claim(_ id: UUID, isLoaded: Bool, wireIsUp: Bool) -> Bool {
        guard wireIsUp, !isLoaded else { return false }
        return asked.insert(id).inserted
    }

    /// A replay arrived, so the chat needs no further ask.
    public mutating func markAnswered(_ id: UUID) { asked.insert(id) }

    /// A fresh session list forgets every ask: the Mac may have restarted or the phone reconnected.
    public mutating func removeAll() { asked = [] }
}
