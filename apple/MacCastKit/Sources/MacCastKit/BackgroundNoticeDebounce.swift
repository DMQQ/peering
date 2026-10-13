import Foundation

/// Decides when the Mac is told the app left the foreground. `.inactive` also covers Control Center, a Face ID prompt and the app switcher, which return within moments and must not pause the Mac's picture; only `.background`, or an `.inactive` that lasts, does.
public struct BackgroundNoticeDebounce: Equatable, Sendable {
    public static let inactiveDelay: TimeInterval = 1

    public enum Action: Equatable, Sendable {
        case none
        case tell(background: Bool)
        /// Ask again at this time with ``fire(now:)``.
        case wait(until: ContinuousClock.Instant)
    }

    private var inactiveSince: ContinuousClock.Instant?

    public init() {}

    public mutating func becameInactive(now: ContinuousClock.Instant) -> Action {
        if inactiveSince == nil { inactiveSince = now }
        return .wait(until: (inactiveSince ?? now) + .seconds(Self.inactiveDelay))
    }

    public mutating func becameBackground() -> Action {
        inactiveSince = nil
        return .tell(background: true)
    }

    public mutating func becameActive() -> Action {
        inactiveSince = nil
        return .tell(background: false)
    }

    /// The delay ran out. Does nothing when the app came back first.
    public mutating func fire(now: ContinuousClock.Instant) -> Action {
        guard let since = inactiveSince, now >= since + .seconds(Self.inactiveDelay) else { return .none }
        inactiveSince = nil
        return .tell(background: true)
    }
}
