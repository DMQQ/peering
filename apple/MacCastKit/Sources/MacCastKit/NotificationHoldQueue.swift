import Foundation

/// Notifications held for a relay that is not reachable, kept only while they are still worth sending.
public struct NotificationHoldQueue<Item: Sendable>: Sendable {
    public static var timeToLive: TimeInterval { 600 }
    public static var capacity: Int { 16 }
    public static var perToken: Int { 4 }
    /// Between two plain notifications for one token and source; one carrying an action is an answerable question and is never dropped for this.
    public static var cooldown: TimeInterval { 5 }

    public struct Entry: Sendable {
        public let item: Item
        public let token: String
        public let at: Date
    }

    private var entries: [Entry] = []
    private var lastPlain: [String: Date] = [:]

    public init() {}

    public var count: Int { entries.count }

    /// - Returns: how many entries were dropped to make room, or nil when the new one was held back by the cooldown.
    public mutating func add(_ item: Item, token: String, source: String?, answerable: Bool, now: Date) -> Int? {
        let key = token + "|" + (source ?? "")
        if !answerable {
            if let last = lastPlain[key], now.timeIntervalSince(last) < Self.cooldown { return nil }
            lastPlain[key] = now
        }
        var dropped = discardExpired(now: now)
        entries.append(Entry(item: item, token: token, at: now))
        dropped += trim(token: token)
        let overflow = max(0, entries.count - Self.capacity)
        entries.removeFirst(overflow)
        return dropped + overflow
    }

    /// Takes everything still worth sending, oldest first.
    public mutating func drain(now: Date) -> [Entry] {
        _ = discardExpired(now: now)
        defer { entries.removeAll() }
        return entries
    }

    /// Puts back what the relay did not take, ahead of anything queued since.
    public mutating func requeue(_ returned: [Entry]) {
        entries.insert(contentsOf: returned, at: 0)
        let overflow = max(0, entries.count - Self.capacity)
        entries.removeFirst(overflow)
    }

    /// For a token the Mac no longer holds, such as one whose device was unpaired.
    public mutating func forget(token: String) {
        entries.removeAll { $0.token == token }
        lastPlain = lastPlain.filter { !$0.key.hasPrefix(token + "|") }
    }

    public mutating func forgetAll() {
        entries.removeAll()
        lastPlain.removeAll()
    }

    private mutating func discardExpired(now: Date) -> Int {
        let before = entries.count
        entries.removeAll { now.timeIntervalSince($0.at) > Self.timeToLive }
        lastPlain = lastPlain.filter { now.timeIntervalSince($0.value) <= Self.timeToLive }
        return before - entries.count
    }

    private mutating func trim(token: String) -> Int {
        var surplus = entries.filter { $0.token == token }.count - Self.perToken
        guard surplus > 0 else { return 0 }
        let dropped = surplus
        entries.removeAll { entry in
            guard surplus > 0, entry.token == token else { return false }
            surplus -= 1
            return true
        }
        return dropped
    }
}
