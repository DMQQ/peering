import Foundation

/// Lets a failure that repeats on every frame reach the log once per interval, with a count of what was held back.
public struct FailureLogGate: Sendable, Equatable {
    public enum Admission: Sendable, Equatable {
        case log(suppressed: Int)
        case suppress
    }

    public let interval: TimeInterval
    private var lastLoggedAt: TimeInterval?
    private var suppressed = 0

    public init(interval: TimeInterval = 5) {
        self.interval = interval
    }

    public mutating func admit(at now: TimeInterval) -> Admission {
        if let lastLoggedAt, now - lastLoggedAt < interval {
            suppressed += 1
            return .suppress
        }
        lastLoggedAt = now
        defer { suppressed = 0 }
        return .log(suppressed: suppressed)
    }
}
