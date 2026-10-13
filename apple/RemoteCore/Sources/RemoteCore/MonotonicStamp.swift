import Foundation

/// A moment on the monotonic clock, for timeouts and gaps. `Date` follows the wall clock, which jumps when the network sets the time or the person changes it, so a "within 60 seconds" test built on it can pass or fail for no reason. Timestamps shown to a person or stored belong in `Date`.
public struct MonotonicStamp: Sendable, Equatable {
    public let instant: ContinuousClock.Instant

    public init(_ instant: ContinuousClock.Instant = .now) {
        self.instant = instant
    }

    public func elapsed(at now: ContinuousClock.Instant = .now) -> Duration {
        instant.duration(to: now)
    }

    /// Seconds as a double, for the places that report a latency.
    public func elapsedSeconds(at now: ContinuousClock.Instant = .now) -> TimeInterval {
        let parts = elapsed(at: now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    public func isWithin(_ limit: Duration, at now: ContinuousClock.Instant = .now) -> Bool {
        elapsed(at: now) < limit
    }

    public func isWithin(seconds limit: TimeInterval, at now: ContinuousClock.Instant = .now) -> Bool {
        isWithin(.seconds(limit), at: now)
    }
}
