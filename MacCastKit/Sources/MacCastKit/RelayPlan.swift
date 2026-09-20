import Foundation

/// The plan the app is on, and the ladder the plans are ordered on.
///
/// **Here rather than in the app target, because the ladder is what the feature map is keyed on.**
/// The map itself is ``PlanCapability``, and a map whose keys live in a package while its ladder
/// lives in a view would be two orderings of the same four rungs, kept in step by hand. This file
/// and that one are the whole of the ladder: the app's `StoreManager` reads its plan from the App
/// Store and hands it over, and nothing else decides what a plan is called or what it sits above.
///
/// **What the plan is a claim about.** What the relay meters by is the JWS StoreKit signed for the
/// live transaction, which the relay verifies against Apple's published root and which names the
/// product, so a modified app that says `plus` without one is metered by the plan it claims
/// only for as long as the relay keeps believing claims at all. The relay's `storekit.rs` holds that
/// reasoning and the condition for ending it; the short version is that reading an unproven `plus`
/// as free on the day the verification shipped would have taken every existing subscriber down to
/// the free allowance, which is why the claim still decides anything at all.
///
/// **The numbers are the relay's, repeated here.** `Relay/src/config.rs` holds the authority:
/// fifteen minutes free and three hours on Relay, both per rolling 24-hour window, and no limit at
/// all above that (`PEERINGD_FREE_MINUTES`, `PEERINGD_RELAY_MINUTES`). This mirrors them so the bar
/// in the Sessions tab can be drawn without asking the server, and the copy in the app's paywall,
/// its introduction and `Relay/site` states the same facts again. Edit one without the others and
/// the bar lies about the allowance it is drawing.
public enum RelayPlan: String, CaseIterable, Sendable {
    case free
    case relay
    case plus
    case pro

    /// Seconds of relay this plan allows in one window, or `nil` for no limit.
    ///
    /// `nil` is the absence of a number rather than a very large one, which is the distinction the
    /// relay makes too: an unlimited plan is not metered, so there is nothing to count and no bar
    /// to draw. It is also why this is not an optional the caller has to guess the meaning of:
    /// ``isUnlimited`` says which it is.
    public var allowanceSeconds: TimeInterval? {
        switch self {
        case .free: return 15 * 60
        case .relay: return 180 * 60
        case .plus, .pro: return nil
        }
    }

    public var isUnlimited: Bool { allowanceSeconds == nil }

    /// The allowance in the app's own words, for the copy that names it.
    ///
    /// Here rather than typed into four screens: "three hours" written beside a number that says
    /// 18,000 seconds is the drift this file exists to prevent, and a sentence assembled from this
    /// cannot disagree with the bar.
    public var allowanceSpelling: String {
        switch self {
        case .free: return "fifteen minutes"
        case .relay: return "three hours"
        case .plus, .pro: return "unlimited relay"
        }
    }

    /// The plan's own name, in the words the paywall's cards use.
    ///
    /// `plus` is the wire name rather than a person's: the relay, the product identifiers and the
    /// handshake all say `plus`, and the card says "Relay Plus". Both spellings are here so that a
    /// lock promising what unlocks a feature says the word the user will find on the card.
    public var name: String {
        switch self {
        case .free: return "Free"
        case .relay: return "Relay"
        case .plus: return "Relay Plus"
        case .pro: return "Pro"
        }
    }

    /// The plan's name for a badge, which is shorter than ``name`` because a capsule the size of a
    /// toolbar glyph has room for four or five letters and no more.
    ///
    /// "Relay Plus" is two words and would arrive as a hyphenated smear at that size, so the badge
    /// says PLUS and the paywall it opens says "Relay Plus" in full. The two are the same plan; only
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
    /// Asked of a ``PlanAccess`` rather than of a plan directly, and that is the whole of how a
    /// paying subscriber is kept out of a locked app on launch: see there for why the answer to
    /// this question has a third state.
    public func includes(_ capability: PlanCapability) -> Bool {
        self >= capability.minimumPlan
    }
}

/// The ladder, which is the order of `allCases` and nothing else.
///
/// `allCases` order rather than a hand-written rank, because the app already reads the ladder this
/// way in two places (the best of a set of live subscriptions is its last member, and the paywall
/// draws its cards in this order), and a rank written as four integers is the copy that stops
/// matching the day a rung is inserted rather than appended.
extension RelayPlan: Comparable {
    public static func < (lhs: RelayPlan, rhs: RelayPlan) -> Bool {
        guard let left = allCases.firstIndex(of: lhs),
              let right = allCases.firstIndex(of: rhs)
        else { return false }
        return left < right
    }
}
