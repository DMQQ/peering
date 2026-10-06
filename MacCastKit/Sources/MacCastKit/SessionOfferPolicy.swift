import Foundation

public struct SessionOfferPolicy: Sendable {
    /// Three doors, three different sentences: first finished session, allowance nearly gone, allowance gone.
    public enum Reason: Equatable, Sendable {
        case firstSession
        /// The relay session that ended left this much of the window's allowance.
        case runningLow(remaining: TimeInterval)
        case quotaExhausted
    }

    /// What an offer spends once it has actually been shown. The first-session offer is remembered
    /// once ever and the running-low one once per window.
    public enum Consumption: Equatable, Sendable {
        case firstSession
        case lowAllowance
    }

    public struct Decision: Equatable, Sendable {
        public let reason: Reason
        public let consumption: Consumption
    }

    public struct State: Sendable {
        public var hasOfferedAfterFirstSession: Bool
        public var planIsUnlimited: Bool
        public var hasPaywallOpen: Bool
        public var hasPendingOffer: Bool
        public var relayAllowanceRemainingFraction: Double?
        public var relaySecondsRemainingEstimate: TimeInterval?
        public var currentWindow: Double
        public var offeredWindow: Double

        public init(
            hasOfferedAfterFirstSession: Bool,
            planIsUnlimited: Bool,
            hasPaywallOpen: Bool,
            hasPendingOffer: Bool,
            relayAllowanceRemainingFraction: Double?,
            relaySecondsRemainingEstimate: TimeInterval?,
            currentWindow: Double,
            offeredWindow: Double
        ) {
            self.hasOfferedAfterFirstSession = hasOfferedAfterFirstSession
            self.planIsUnlimited = planIsUnlimited
            self.hasPaywallOpen = hasPaywallOpen
            self.hasPendingOffer = hasPendingOffer
            self.relayAllowanceRemainingFraction = relayAllowanceRemainingFraction
            self.relaySecondsRemainingEstimate = relaySecondsRemainingEstimate
            self.currentWindow = currentWindow
            self.offeredWindow = offeredWindow
        }
    }

    /// A fraction so the threshold follows the allowance if the free plan changes.
    public static let lowRelayAllowanceFraction: Double = 0.25

    /// A floor excluding the mistaken connect and the immediate drop. Set low because no offer at all never opens again.
    public static let minimumOfferableSessionDuration: TimeInterval = 20

    /// The offer is decided on teardown, before the remote screen has handed back to the picker; presenting then would put a purchase sheet over a leaving screen.
    public static let offerAfterSessionDelay: TimeInterval = 0.55

    /// The two offers are ordered, not ranked: someone who never finished a session gets the full case even if their allowance is low.
    public static func decision(after record: ClientSessionRecord, state: State) -> Decision? {
        // No allowance means nothing to be low on.
        guard !state.planIsUnlimited else { return nil }
        // Replacing the paywall already up would rewrite a screen being read.
        guard !state.hasPaywallOpen, !state.hasPendingOffer else { return nil }

        if !state.hasOfferedAfterFirstSession,
           record.duration >= Self.minimumOfferableSessionDuration {
            return Decision(reason: .firstSession, consumption: .firstSession)
        }

        // Past the first offer, only a nearly gone allowance is worth it, and only if this session spent some.
        guard record.path == .relay,
              let fraction = state.relayAllowanceRemainingFraction,
              fraction <= Self.lowRelayAllowanceFraction,
              let remaining = state.relaySecondsRemainingEstimate,
              state.offeredWindow != state.currentWindow
        else { return nil }

        // Spent and nearly spent are different sentences, and only one of them is true at zero.
        // Zero is the wall the relay itself refuses at, so it gets the wall's words.
        return Decision(
            reason: remaining <= 0 ? .quotaExhausted : .runningLow(remaining: remaining),
            consumption: .lowAllowance
        )
    }
}
