import Foundation

/// The user's plan, or the fact that the app does not know yet.
public enum PlanAccess: Sendable, Equatable {
    /// The App Store has not answered yet. Locks nothing; see the note above.
    case unknown
    case known(RelayPlan)

    public var plan: RelayPlan? {
        switch self {
        case .unknown: return nil
        case .known(let plan): return plan
        }
    }

    /// Whether the Sessions screen has a relay allowance to show.
    public var showsRelayAllowance: Bool {
        self == .known(.free)
    }
}
