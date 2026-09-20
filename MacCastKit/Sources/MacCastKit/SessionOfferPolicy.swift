import Foundation

/// Whether the session that just ended is worth asking the user to subscribe over.
///
/// **The decision, and only the decision.** The app holds the answer for half a second, re-checks
/// the moment, and then puts a sheet up. None of that can be tested without an app bundle,
/// a store and a live session, which is how the rule came to be untested while the timing around it
/// was the part with comments about how easy it is to get wrong.
///
/// So the rule is here and the effects are there. Everything this reads arrives as
/// ``State``, including the two things that are not about the session at all (whether the user is
/// already looking at a paywall, and whether the plan is one that has an allowance to run low on),
/// so that the whole of it can be exercised by writing those down.
///
/// **Nothing here decides what to sell.** ``Reason`` names the door; `PaywallView` is where the
/// words are, and it is told which of the three it is opening.
public struct SessionOfferPolicy: Sendable {
    /// Why the app would be asking.
    ///
    /// Three doors rather than a `Bool`, because they are three different sentences: the first
    /// session this device ever finished, an allowance that is nearly gone, and one that is gone.
    /// "41m left" and "none left" are not the same news.
    public enum Reason: Equatable, Sendable {
        case firstSession
        /// The relay session that ended left this much of the window's allowance.
        case runningLow(remaining: TimeInterval)
        case quotaExhausted
    }

    /// What an offer spends once it has actually been shown.
    ///
    /// The two are remembered differently, the first-session offer once ever and the running-low
    /// one once per window, so which one was spent is as much of the decision as which one it was.
    public enum Consumption: Equatable, Sendable {
        case firstSession
        case lowAllowance
    }

    public struct Decision: Equatable, Sendable {
        public let reason: Reason
        public let consumption: Consumption
    }

    /// Everything the decision reads.
    ///
    /// A struct rather than the model itself so that a test can say "a relay session, allowance
    /// nearly gone, nothing open, nobody asked yet" in one place, and so that this module never
    /// learns what an `SessionModel` is.
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
    /// A fraction rather than a number of minutes, because the two metered plans are six times
    /// apart: a quarter of free's half hour is seven minutes and a quarter of Relay's three hours is
    /// forty-five. Written in minutes it would be either an alarm for one of them or nothing for the
    /// other, and what this is really marking is the point where the figure on the meter stops being
    /// comfortable and starts being a deadline, which is a proportion, not a duration.
    public static let lowRelayAllowanceFraction: Double = 0.25

    /// The shortest session that counts as having used the app.
    ///
    /// A floor, and not a judgement of quality: it exists to exclude the connect that was a mistake
    /// and the one that immediately dropped, both of which are over in seconds. It is set low
    /// because the two ways of getting this wrong are not symmetrical: an offer after a short real
    /// session is mildly forward, where no offer after one is a door that never opens again, since
    /// this is asked once ever.
    public static let minimumOfferableSessionDuration: TimeInterval = 20

    /// The beat between a session ending and the offer that follows it.
    ///
    /// The offer is decided on the teardown, which happens *before* the remote screen has handed
    /// back to the picker, so presenting it there would put a purchase sheet on top of a screen that
    /// is already leaving, both animations arriving together. The screen change is the thing being
    /// looked at, and it is allowed to be seen before anything is asked of the user.
    ///
    /// Read by the app rather than here: this type decides *whether*, and holding the answer for a
    /// beat is an effect.
    public static let offerAfterSessionDelay: TimeInterval = 0.55

    /// Whether this session, ending now, is worth an offer, or `nil` for the great majority that
    /// are not.
    ///
    /// The two offers are ordered rather than ranked. Somebody who has never finished a session is
    /// hearing about the relay for the first time, and ought to get the whole case rather than the
    /// running-low version of it, even if their allowance happens to be low already.
    public static func decision(after record: ClientSessionRecord, state: State) -> Decision? {
        // A plan with no allowance has nothing to be low on, and an unmetered subscriber has already
        // bought the thing this would be selling.
        guard !state.planIsUnlimited else { return nil }
        // Somebody is already looking at a paywall: the relay refused this connection for quota, or
        // the user opened it themselves from the Sessions tab. There is one `paywallReason`, and
        // replacing the one that is up would rewrite a screen that is being read.
        guard !state.hasPaywallOpen, !state.hasPendingOffer else { return nil }

        if !state.hasOfferedAfterFirstSession,
           record.duration >= Self.minimumOfferableSessionDuration {
            return Decision(reason: .firstSession, consumption: .firstSession)
        }

        // Past the first offer, the only thing left worth interrupting for is an allowance that is
        // nearly gone, and only on a session that actually spent some of it, because that is the
        // session in which the user watched the meter move. Somebody whose afternoon was all LAN
        // sees the same figure on the Sessions tab, which is where a number belongs when nothing has
        // just happened to it.
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
