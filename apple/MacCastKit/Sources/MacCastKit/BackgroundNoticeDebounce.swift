import Foundation

/// Decides when the Mac is told the app left the foreground. `.inactive` also covers Control Center, a Face ID prompt and the app switcher, which return within moments and must not pause the Mac's picture; only `.background`, or an `.inactive` that lasts, does.
public struct BackgroundNoticeDebounce: Equatable, Sendable {
    public static let inactiveDelay: TimeInterval = 1

    public enum Action: Equatable, Sendable {
        case none
        case tell(background: Bool)
        /// Ask again at this time with ``fire(now:)``.
        case wait(until: Date)
    }

    private var inactiveSince: Date?

    public init() {}

    public mutating func becameInactive(now: Date) -> Action {
        if inactiveSince == nil { inactiveSince = now }
        return .wait(until: (inactiveSince ?? now).addingTimeInterval(Self.inactiveDelay))
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
    public mutating func fire(now: Date) -> Action {
        guard let since = inactiveSince, now >= since.addingTimeInterval(Self.inactiveDelay) else { return .none }
        inactiveSince = nil
        return .tell(background: true)
    }
}
