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
}
