import Foundation

/// When the attempt at a direct path knocks, asks the relay where the peer is, and gives up: one schedule for both ends, restarted when the network under it changes.
public struct DirectPathSchedule: Sendable {
    public static let fastAttempts = 12
    public static let fastInterval: Duration = .milliseconds(250)
    /// The rest of the session: enough to recover a path a NAT mapping expiry took away, cheap enough to leave running.
    public static let slowInterval: Duration = .seconds(5)
    /// Attempts between two asks at the relay for the peer's address: one per three seconds while fast, one per minute once slowed.
    public static let rediscoverEvery = 12

    private var attempt = 0
    private var startedAt: ContinuousClock.Instant

    public init(now: ContinuousClock.Instant = .now) {
        startedAt = now
    }

    public var asksRelayForPeerAddress: Bool { attempt % Self.rediscoverEvery == 0 }

    public mutating func probeSent() {
        attempt += 1
    }

    /// How long to wait before the next probe.
    public var intervalToNextProbe: Duration {
        attempt <= Self.fastAttempts ? Self.fastInterval : Self.slowInterval
    }

    public func verdictIsDue(now: ContinuousClock.Instant) -> Bool {
        ClientSession.DirectPath.verdictIsDue(after: now - startedAt)
    }

    /// A new network makes the old mapping and the old verdict meaningless: knock fast again, ask the relay at once, and give the new attempt its own time.
    public mutating func restart(now: ContinuousClock.Instant) {
        attempt = 0
        startedAt = now
    }
}
