import Foundation

/// How long to wait before registering with the relay again.
/// A relay that accepts a registration and drops it at once must not reset the back-off, and a fleet of Macs must not retry on one schedule after a relay restart.
public struct ReconnectPolicy: Sendable {
    public static let delays: [TimeInterval] = [1, 2, 5, 10, 30]
    public static let stableAfter: TimeInterval = 60
    public static let jitterRange: ClosedRange<Double> = 0.2...0.5

    private var attempt = 0
    private var registeredSince: Date?

    public init() {}

    public mutating func registered(at now: Date) {
        if registeredSince == nil { registeredSince = now }
    }

    /// - Parameter jitter: a value in 0...1 that picks a point in ``jitterRange``.
    public mutating func delayAfterEnd(at now: Date, jitter: Double) -> TimeInterval {
        if let since = registeredSince, now.timeIntervalSince(since) >= Self.stableAfter {
            attempt = 0
        }
        registeredSince = nil

        let base = Self.delays[min(attempt, Self.delays.count - 1)]
        attempt += 1
        let unit = min(max(jitter, 0), 1)
        let extra = Self.jitterRange.lowerBound + unit * (Self.jitterRange.upperBound - Self.jitterRange.lowerBound)
        return base * (1 + extra)
    }
}

/// Counts pings the relay has not answered, so a half-open socket is torn down rather than shown as registered.
public struct SignallingLiveness: Sendable, Equatable {
    public static let tolerableMissedPings = 2

    private var unanswered = 0

    public init() {}

    /// Anything arriving from the relay proves the socket carries data both ways.
    public mutating func heard() {
        unanswered = 0
    }

    /// - Returns: whether the connection is dead and must be replaced instead of pinged.
    public mutating func pingDue() -> Bool {
        if unanswered >= Self.tolerableMissedPings { return true }
        unanswered += 1
        return false
    }
}
