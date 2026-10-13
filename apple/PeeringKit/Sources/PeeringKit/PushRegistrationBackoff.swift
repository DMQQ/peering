import Foundation

/// How long to wait before asking APNs for a token again. APNs fails on a bad network or a short outage and says nothing when it recovers, so without a retry a phone stays unreachable until the app is relaunched.
public struct PushRegistrationBackoff: Equatable, Sendable {
    public static let delays: [TimeInterval] = [5, 30, 120, 600]

    public private(set) var failures = 0

    public init() {}

    /// - Returns: seconds to wait before the next attempt; the last step repeats.
    public mutating func failed() -> TimeInterval {
        let delay = Self.delays[min(failures, Self.delays.count - 1)]
        failures += 1
        return delay
    }

    public mutating func succeeded() {
        failures = 0
    }
}
