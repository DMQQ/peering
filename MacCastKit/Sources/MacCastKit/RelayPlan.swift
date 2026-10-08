import Foundation

/// Mirrors the relay's allowance (`Relay/src/config.rs`: 30 minutes free per rolling 24-hour window, unlimited on paid plans). The paywall copy and `Relay/site` state the same facts, so edit them together.
public enum RelayPlan: String, CaseIterable, Sendable {
    case free
    case relay
    case pro

    /// Seconds of relay allowed per window; `nil` is unlimited (not metered), not a large number.
    public var allowanceSeconds: TimeInterval? {
        switch self {
        case .free: return 30 * 60
        case .relay, .pro: return nil
        }
    }

    public var isUnlimited: Bool { allowanceSeconds == nil }

    public var allowanceSpelling: String {
        switch self {
        case .free: return String(localized: "30 minutes")
        case .relay, .pro: return String(localized: "unlimited relay")
        }
    }

    public var name: String {
        switch self {
        case .free: return String(localized: "Free")
        case .relay: return String(localized: "Relay")
        case .pro: return String(localized: "Pro")
        }
    }

    /// Shorter than ``name``, for a badge capsule.
    public var badge: String {
        switch self {
        case .free: return "FREE"
        case .relay: return "RELAY"
        case .pro: return "PRO"
        }
    }

    /// Asked of a ``PlanAccess`` rather than a plan, so the answer has a third state.
    public func includes(_ capability: PlanCapability) -> Bool {
        self >= capability.minimumPlan
    }
}

/// The order of `allCases`; a hand-written rank would drift when a rung is inserted.
extension RelayPlan: Comparable {
    public static func < (lhs: RelayPlan, rhs: RelayPlan) -> Bool {
        guard let left = allCases.firstIndex(of: lhs),
              let right = allCases.firstIndex(of: rhs)
        else { return false }
        return left < right
    }
}
