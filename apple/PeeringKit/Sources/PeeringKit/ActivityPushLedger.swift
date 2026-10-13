import Foundation

/// Remembers which phone and token each Live Activity push went to, so a refusal that names the push can be tied to it.
///
/// The relay echoes the `requestId` a push carried. Without one (an older relay) the most recent push is the best guess.
public struct ActivityPushLedger: Sendable {
    public struct Entry: Sendable, Equatable {
        public var clientID: String
        public var token: String
    }

    /// A refusal arrives within a round trip; a minute is generous.
    public static let retention: Duration = .seconds(60)

    private struct Remembered {
        var entry: Entry
        var at: ContinuousClock.Instant
    }

    private var byRequest: [String: Remembered] = [:]
    private var latest: Entry?

    public init() {}

    /// Eight hex characters, well inside the relay's 64.
    public static func makeRequestID() -> String {
        String(format: "%08x", UInt32.random(in: .min ... .max))
    }

    public mutating func record(requestId: String, clientID: String, token: String, now: ContinuousClock.Instant) {
        byRequest = byRequest.filter { now - $0.value.at < Self.retention }
        let entry = Entry(clientID: clientID, token: token)
        byRequest[requestId] = Remembered(entry: entry, at: now)
        latest = entry
    }

    /// With an id, exactly that push or nothing (a forgotten one must not condemn another token). Without one, the latest push.
    public func entry(for requestId: String?, now: ContinuousClock.Instant) -> Entry? {
        guard let requestId else { return latest }
        guard let remembered = byRequest[requestId], now - remembered.at < Self.retention else { return nil }
        return remembered.entry
    }
}
