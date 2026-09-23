import Foundation

/// The plan the app is on, and the ladder the plans are ordered on.
///
/// The ladder is what the feature map, ``PlanCapability``, is keyed on. What the relay meters by is
/// the JWS StoreKit signed for the live transaction, verified against Apple's published root.
///
/// The numbers are the relay's: `Relay/src/config.rs` holds the authority, one hour free per
/// rolling 24-hour window (`PEERINGD_FREE_MINUTES`), no limit on any paid plan. This mirrors that
/// so the Sessions tab's bar can be drawn without asking the server, and the paywall's copy and
/// `Relay/site` state the same facts. Edit one without the others and the bar lies.
public enum RelayPlan: String, CaseIterable, Sendable {
    case free
    case relay
    case plus
    case pro

    /// Seconds of relay this plan allows in one window, or `nil` for no limit.
    ///
    /// `nil` is the absence of a number rather than a very large one, the distinction the relay
    /// makes too: an unlimited plan is not metered, so there is nothing to count. ``isUnlimited``
    /// says which it is.
    public var allowanceSeconds: TimeInterval? {
        switch self {
        case .free: return 60 * 60
        case .relay, .plus, .pro: return nil
        }
    }

    public var isUnlimited: Bool { allowanceSeconds == nil }

    /// The allowance in the app's own words, for the copy that names it.
    ///
    /// Here rather than typed into four screens, where "one hour" drifts from the 7,200 seconds
    /// beside it.
    public var allowanceSpelling: String {
        switch self {
        case .free: return "one hour"
        case .relay, .plus, .pro: return "unlimited relay"
        }
    }

    /// The plan's own name, in the words the paywall's cards use.
    ///
    /// `plus` is the wire name: the relay, the product identifiers and the handshake all say it,
    /// while the card says "Relay Plus".
    public var name: String {
        switch self {
        case .free: return "Free"
        case .relay: return "Relay"
        case .plus: return "Relay Plus"
        case .pro: return "Pro"
        }
    }

    /// The plan's name for a badge, which is shorter than ``name`` because a capsule the size of a
    /// toolbar glyph has room for four or five letters and no more. The two are the same plan; only
    /// the room differs.
    public var badge: String {
        switch self {
        case .free: return "FREE"
        case .relay: return "RELAY"
        case .plus: return "PLUS"
        case .pro: return "PRO"
        }
    }

    /// Whether this plan includes a feature, which is the one question every gate in the app asks.
    ///
    /// Asked of a ``PlanAccess`` rather than of a plan directly, so the answer has a third state.
    /// See there.
    public func includes(_ capability: PlanCapability) -> Bool {
        self >= capability.minimumPlan
    }
}

/// The ladder, which is the order of `allCases` and nothing else.
///
/// `allCases` order rather than a hand-written rank, which is the copy that stops matching the day
/// a rung is inserted rather than appended.
extension RelayPlan: Comparable {
    public static func < (lhs: RelayPlan, rhs: RelayPlan) -> Bool {
        guard let left = allCases.firstIndex(of: lhs),
              let right = allCases.firstIndex(of: rhs)
        else { return false }
        return left < right
    }
}
