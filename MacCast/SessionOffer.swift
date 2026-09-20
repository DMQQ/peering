import Foundation
import MacCastKit
import RemoteCore

/// When the app asks the user to subscribe, and how often it is allowed to ask.
///
/// Two doors, and they are different doors: the first session anybody finishes, which is the first
/// moment the app has proved it does something, and a relay allowance that is nearly spent, which is
/// the moment the proof is about to stop. Neither is the relay refusing a connection — that door
/// already exists and is a wall the user walked into, where these two are the app speaking first.
///
/// **The rule is in ``MacCastKit/SessionOfferPolicy`` and the doing is here.** Whether this session
/// is worth an offer is a question about a record and a handful of facts, and it is the half that can
/// be wrong in a way nobody notices: an offer that never arrives costs a sale silently, and one that
/// arrives twice is a nag the user has no switch for. That half is tested where it can be run. What
/// is left here is the effect: hold the answer for a beat, look again, then spend it. That needs
/// a running app to happen at all.
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
    /// Whether the one-time offer that follows the first finished session has been made.
    var hasOfferedAfterFirstSession: Bool {
        get { UserDefaults.standard.bool(forKey: PreferenceKeys.offeredAfterFirstSession) }
        set { UserDefaults.standard.set(newValue, forKey: PreferenceKeys.offeredAfterFirstSession) }
    }

    /// Which window the running-low offer was last made in, or 0 for never.
    ///
    /// The window's own number rather than a date, because the only question ever asked of it is
    /// whether it is the window we are in now. Zero is safe as "never": the number is epoch seconds
    /// divided into days, which has been in the twenty-thousands for fifty years, and
    /// `double(forKey:)` answers zero for a key that was never written — which is the answer that
    /// means "not yet".
    var lowRelayOfferWindow: Double {
        get { UserDefaults.standard.double(forKey: PreferenceKeys.lowRelayOfferWindow) }
        set { UserDefaults.standard.set(newValue, forKey: PreferenceKeys.lowRelayOfferWindow) }
    }

    /// Decides whether the session that just ended is worth an offer, and arms it if it is.
    ///
    /// Called from ``finishSessionHistory()``, which is the one place a session is filed, so this
    /// runs for every session that ever reached `.ready` and for nothing else.
    func offerSubscriptionIfDue(after record: ClientSessionRecord) {
        guard let decision = SessionOfferPolicy.decision(after: record, state: offerState) else {
            return
        }
        armOffer(decision.reason, consuming: decision.consumption)
    }

    /// Everything the rule reads, gathered from where each piece actually lives.
    ///
    /// The three that are not about the session are the reason this is worth writing down: whether
    /// the user is already looking at a paywall, whether an offer is already in flight, and whether
    /// the plan has an allowance to run low on at all. Reading them here rather than passing the
    /// whole model in is what keeps the rule testable, and it also puts the four or five facts it
    /// really depends on in one place to be read.
    private var offerState: SessionOfferPolicy.State {
        SessionOfferPolicy.State(
            hasOfferedAfterFirstSession: hasOfferedAfterFirstSession,
            planIsUnlimited: storeManager.relayPlan.isUnlimited,
            hasPaywallOpen: paywallReason != nil,
            hasPendingOffer: pendingOffer != nil,
            relayAllowanceRemainingFraction: relayAllowanceRemainingFraction,
            relaySecondsRemainingEstimate: relaySecondsRemainingEstimate,
            currentWindow: relayWindowNumber,
            offeredWindow: lowRelayOfferWindow
        )
    }

    /// Holds the reason for a beat, then shows it — unless the moment has passed.
    ///
    /// The guards are asked again when the sleep ends rather than trusted from when it began,
    /// because half a second is long enough for the app to have changed its mind about what it is
    /// doing: a dropped session starts a reconnect ladder, and an upsell over a screen that is
    /// trying to get the user back is an interruption with nothing behind it. Nothing re-arms the
    /// offer in that case, and the flag is untouched — so it is still there for the next session,
    /// and the running-low figure is on the Sessions tab for anyone who goes looking.
    ///
    /// **The flag and the window are written at presentation rather than at the decision**, which is
    /// the whole reason this is separate from the rule. An offer that is decided and then never
    /// shown — because a reconnect started in the half-second between, or because the user opened
    /// the paywall themselves — must not have spent its one chance. A flag written at the decision
    /// would silence the first offer for good on a session that dropped.
    private func armOffer(
        _ reason: SessionOfferPolicy.Reason,
        consuming: SessionOfferPolicy.Consumption
    ) {
        pendingOffer = Task { [weak self] in
            // Cleared on every exit, including the ones that show nothing. A task left armed behind
            // a guard that failed would block the next real offer for the life of the app.
            defer { self?.pendingOffer = nil }

            try? await Task.sleep(for: .seconds(SessionOfferPolicy.offerAfterSessionDelay))

            guard let self, !Task.isCancelled, !phase.holdsSession, paywallReason == nil else {
                return
            }
            switch consuming {
            case .firstSession: hasOfferedAfterFirstSession = true
            case .lowAllowance: lowRelayOfferWindow = relayWindowNumber
            }
            paywallReason = Self.paywallReason(for: reason)
        }
    }

    /// The policy's three doors as the three the sheet knows how to open.
    ///
    /// A mapping rather than one shared enum, because the two types are answering different
    /// questions: the policy is deciding, and ``PaywallView`` is choosing words, and the words are
    /// in a SwiftUI view, which is the one place this module cannot follow it to.
    private static func paywallReason(for reason: SessionOfferPolicy.Reason) -> PaywallView.Reason {
        switch reason {
        case .firstSession: return .firstSession
        case .runningLow(let remaining): return .runningLow(remaining: remaining)
        case .quotaExhausted: return .quotaExhausted
        }
    }
}
