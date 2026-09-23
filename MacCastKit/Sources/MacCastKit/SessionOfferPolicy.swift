import Foundation

/// Whether the session that just ended is worth asking the user to subscribe over.
///
/// The decision and only the decision, so that it can be exercised without an app bundle, a store
/// and a live session: everything it reads arrives as ``State``. Nothing here decides what to sell:
/// ``Reason`` names the door, and `PaywallView` is told which of the three it is opening.
public struct SessionOfferPolicy: Sendable {
    /// Why the app would be asking.
    ///
    /// Three doors rather than a `Bool`, because they are three different sentences: the first
    /// session this device ever finished, an allowance nearly gone, and one that is gone.
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

    /// Everything the decision reads. A struct rather than the model itself, so a test can set the
    /// whole situation down in one place and this module never learns what a `SessionModel` is.
    public struct State: Sendable {
        /// Whether the one-time offer that follows the first finished session has been made.
        public var hasOfferedAfterFirstSession: Bool
        /// Whether the plan has no allowance, and therefore nothing to be low on.
        public var planIsUnlimited: Bool
        /// Whether a paywall is already on screen, the user's own or the relay's refusal.
        public var hasPaywallOpen: Bool
        /// Whether an offer is already armed and waiting out its delay.
        public var hasPendingOffer: Bool
        /// How much of the window's relay allowance is left, 0 to 1, or `nil` if unknown.
        public var relayAllowanceRemainingFraction: Double?
        /// How many seconds of it are left, or `nil` if unknown.
        public var relaySecondsRemainingEstimate: TimeInterval?
        /// Which 24-hour window the relay is counting in now.
        public var currentWindow: Double
        /// Which window the running-low offer was last made in, or 0 for never.
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

    /// How much of the window's allowance has to be left before the app offers to raise it.
    ///
    /// A fraction rather than a number of minutes, so the threshold follows the allowance if the
    /// free plan changes. Paid plans are unlimited and never reach this policy.
    public static let lowRelayAllowanceFraction: Double = 0.25

    /// The shortest session that counts as having used the app.
    ///
    /// A floor, not a judgement of quality: it excludes the connect that was a mistake and the one
    /// that immediately dropped. Set low because no offer at all is the door that never opens again.
    public static let minimumOfferableSessionDuration: TimeInterval = 20

    /// The beat between a session ending and the offer that follows it.
    ///
    /// The offer is decided on the teardown, before the remote screen has handed back to the picker,
    /// so presenting it there would put a purchase sheet on top of a screen that is already leaving.
    public static let offerAfterSessionDelay: TimeInterval = 0.55

    /// Whether this session, ending now, is worth an offer, or `nil` for the great majority that
    /// are not.
    ///
    /// The two offers are ordered rather than ranked: somebody who has never finished a session gets
    /// the whole case rather than the running-low version of it, even if their allowance is low.
    public static func decision(after record: ClientSessionRecord, state: State) -> Decision? {
        // A plan with no allowance has nothing to be low on, and an unmetered subscriber has already
        // bought the thing this would be selling.
        guard !state.planIsUnlimited else { return nil }
        // Somebody is already looking at a paywall, and there is one `paywallReason`: replacing the
        // one that is up would rewrite a screen that is being read.
        guard !state.hasPaywallOpen, !state.hasPendingOffer else { return nil }

        if !state.hasOfferedAfterFirstSession,
           record.duration >= Self.minimumOfferableSessionDuration {
            return Decision(reason: .firstSession, consumption: .firstSession)
        }

        // Past the first offer, the only thing left worth interrupting for is an allowance that is
        // nearly gone, and only on a session that actually spent some of it: that is the session in
        // which the user watched the meter move.
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
