import Foundation
import RemoteCore

/// When the app asks the user to subscribe, and how often it is allowed to ask.
///
/// Two doors, and they are different doors: the first session anybody finishes, which is the first
/// moment the app has proved it does something, and a relay allowance that is nearly spent, which is
/// the moment the proof is about to stop. Neither is the relay refusing a connection — that door
/// already exists and is a wall the user walked into, where these two are the app speaking first.
///
/// **Nothing here decides what to sell.** The reason travels to ``PaywallView`` and that screen says
/// what the money is for; this decides only whether this is a moment worth asking in.
///
/// **Never during a session, and never twice for the same thing.** Both offers are made on a
/// teardown, so the user is on their way back to the picker rather than looking at their Mac — a
/// purchase screen over a live desktop would be competing with the thing it is selling. And both are
/// remembered: the first-session offer is made once ever and the running-low offer once per window,
/// because an app that asks every time is one whose asking stops meaning anything.
extension SessionModel {
    /// How much of the window's allowance has to be left before the app offers to raise it.
    ///
    /// A fraction rather than a number of minutes, because the two metered plans are six times
    /// apart: a quarter of free's half hour is seven minutes and a quarter of Relay's three hours is
    /// forty-five. Written in minutes it would be either an alarm for one of them or nothing for the
    /// other, and what this is really marking is the point where the figure on the meter stops being
    /// comfortable and starts being a deadline — which is a proportion, not a duration.
    static let lowRelayAllowanceFraction: Double = 0.25

    /// The shortest session that counts as having used the app.
    ///
    /// A floor, and not a judgement of quality: it exists to exclude the connect that was a mistake
    /// and the one that immediately dropped, both of which are over in seconds. It is set low
    /// because the two ways of getting this wrong are not symmetrical — an offer after a short real
    /// session is mildly forward, where no offer after one is a door that never opens again, since
    /// this is asked once ever.
    static let minimumOfferableSessionDuration: TimeInterval = 20

    /// The beat between a session ending and the offer that follows it.
    ///
    /// The offer is decided on the teardown, which happens *before* the remote screen has handed
    /// back to the picker — so presenting it there would put a purchase sheet on top of a screen
    /// that is already leaving, both animations arriving together. The same reasoning as the
    /// connecting card's own minimum life: the screen change is the thing being looked at, and it is
    /// allowed to be seen before anything is asked of the user.
    static let offerAfterSessionDelay: TimeInterval = 0.55

    /// Whether the one-time offer that follows the first finished session has been made.
    var hasOfferedAfterFirstSession: Bool {
        get { UserDefaults.standard.bool(forKey: PreferenceKey.offeredAfterFirstSession) }
        set { UserDefaults.standard.set(newValue, forKey: PreferenceKey.offeredAfterFirstSession) }
    }

    /// Which window the running-low offer was last made in, or 0 for never.
    ///
    /// The window's own number rather than a date, because the only question ever asked of it is
    /// whether it is the window we are in now. Zero is safe as "never": the number is epoch seconds
    /// divided into days, which has been in the twenty-thousands for fifty years, and
    /// `double(forKey:)` answers zero for a key that was never written — which is the answer that
    /// means "not yet".
    var lowRelayOfferWindow: Double {
        get { UserDefaults.standard.double(forKey: PreferenceKey.lowRelayOfferWindow) }
        set { UserDefaults.standard.set(newValue, forKey: PreferenceKey.lowRelayOfferWindow) }
    }

    /// Decides whether the session that just ended is worth an offer, and arms it if it is.
    ///
    /// Called from ``finishSessionHistory()``, which is the one place a session is filed, so this
    /// runs for every session that ever reached `.ready` and for nothing else.
    ///
    /// The two offers are ordered rather than ranked. Somebody who has never finished a session is
    /// hearing about the relay for the first time, and ought to get the whole case rather than the
    /// running-low version of it — even if their allowance happens to be low already.
    func offerSubscriptionIfDue(after record: ClientSessionRecord) {
        // A plan with no allowance has nothing to be low on, and an unmetered subscriber has already
        // bought the thing this would be selling.
        guard !storeManager.relayPlan.isUnlimited else { return }
        // Somebody is already looking at a paywall — the relay refused this connection for quota, or
        // the user opened it themselves from the Sessions tab. There is one `paywallReason`, and
        // replacing the one that is up would rewrite a screen that is being read.
        guard paywallReason == nil, pendingOffer == nil else { return }

        if !hasOfferedAfterFirstSession, record.duration >= Self.minimumOfferableSessionDuration {
            armOffer(.firstSession, consuming: .firstSession)
            return
        }

        // Past the first offer, the only thing left worth interrupting for is an allowance that is
        // nearly gone — and only on a session that actually spent some of it, because that is the
        // session in which the user watched the meter move. Somebody whose afternoon was all LAN
        // sees the same figure on the Sessions tab, which is where a number belongs when nothing has
        // just happened to it.
        guard record.path == .relay,
              let fraction = relayAllowanceRemainingFraction,
              fraction <= Self.lowRelayAllowanceFraction,
              let remaining = relaySecondsRemainingEstimate,
              lowRelayOfferWindow != relayWindowNumber
        else { return }

        // Spent and nearly spent are different sentences, and only one of them is true at zero.
        // "41m left" and "none left" are not the same news, and zero is the wall the relay itself
        // refuses at, so it gets the wall's words.
        armOffer(
            remaining <= 0 ? .quotaExhausted : .runningLow(remaining: remaining),
            consuming: .lowAllowance
        )
    }

    /// What an armed offer spends once it has actually been shown.
    ///
    /// Written at presentation rather than at the decision, which is the whole reason this type
    /// exists: an offer that is decided and then never shown — because a reconnect started in the
    /// half-second between, or because the user opened the paywall themselves — must not have spent
    /// its one chance. A flag set at the decision would silence the first offer for good on a
    /// session that dropped.
    private enum OfferConsumption {
        case firstSession
        case lowAllowance
    }

    /// Holds the reason for a beat, then shows it — unless the moment has passed.
    ///
    /// The guards are asked again when the sleep ends rather than trusted from when it began,
    /// because half a second is long enough for the app to have changed its mind about what it is
    /// doing: a dropped session starts a reconnect ladder, and an upsell over a screen that is
    /// trying to get the user back is an interruption with nothing behind it. Nothing re-arms the
    /// offer in that case, and the flag is untouched — so it is still there for the next session,
    /// and the running-low figure is on the Sessions tab for anyone who goes looking.
    private func armOffer(_ reason: PaywallView.Reason, consuming: OfferConsumption) {
        pendingOffer = Task { [weak self] in
            // Cleared on every exit, including the ones that show nothing. A task left armed behind
            // a guard that failed would block the next real offer for the life of the app.
            defer { self?.pendingOffer = nil }

            try? await Task.sleep(for: .seconds(Self.offerAfterSessionDelay))

            guard let self, !Task.isCancelled, !phase.holdsSession, paywallReason == nil else {
                return
            }
            switch consuming {
            case .firstSession: hasOfferedAfterFirstSession = true
            case .lowAllowance: lowRelayOfferWindow = relayWindowNumber
            }
            paywallReason = reason
        }
    }
}
