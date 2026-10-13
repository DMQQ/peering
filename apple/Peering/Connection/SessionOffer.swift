import Foundation
import MacCastKit
import RemoteCore

/// When the app asks the user to subscribe, and how often it is allowed to ask.
/// Two doors: the first finished session and a nearly spent relay allowance. Neither is the relay refusing a connection; that wall already exists.
/// The rule is in ``MacCastKit/SessionOfferPolicy`` and is tested there; the effect (hold the answer for a beat, look again, spend it) needs a running app.
/// Nothing here decides what to sell: the reason travels to ``PaywallView``.
/// Never during a session and never twice: offers are made on teardown so a purchase screen does not compete with a live desktop; the first-session offer is once ever and running-low once per window.
extension SessionModel {
    var hasOfferedAfterFirstSession: Bool {
        get { UserDefaults.standard.bool(forKey: PreferenceKeys.offeredAfterFirstSession) }
        set { UserDefaults.standard.set(newValue, forKey: PreferenceKeys.offeredAfterFirstSession) }
    }

    /// The window's own number, as the only question is whether it is the current one. Zero means never: `double(forKey:)` answers zero for a missing key and real values have been in the twenty-thousands for fifty years.
    var lowRelayOfferWindow: Double {
        get { UserDefaults.standard.double(forKey: PreferenceKeys.lowRelayOfferWindow) }
        set { UserDefaults.standard.set(newValue, forKey: PreferenceKeys.lowRelayOfferWindow) }
    }

    func offerSubscriptionIfDue(after record: ClientSessionRecord) {
        guard let decision = SessionOfferPolicy.decision(after: record, state: offerState) else {
            return
        }
        armOffer(decision.reason, consuming: decision.consumption)
    }

    private var offerState: SessionOfferPolicy.State {
        SessionOfferPolicy.State(
            hasOfferedAfterFirstSession: hasOfferedAfterFirstSession,
            planIsUnlimited: storeManager.relayPlan.isUnlimited,
            hasPaywallOpen: paywallReason != nil,
            hasPendingOffer: pendingOffer != nil,
            relayAllowanceRemainingFraction: relayAllowanceRemainingFraction,
            relaySecondsRemainingEstimate: relaySecondsRemainingEstimate,
            currentWindow: relayWindowNumber,
            offeredWindow: lowRelayOfferWindow,
            relayReport: relayRemainingSecondsFromRelay,
            relayAllowanceSeconds: relayAllowanceSeconds
        )
    }

    /// The guards are asked again when the sleep ends: a dropped session starts a reconnect ladder and an upsell over it is an interruption.
    /// The flag and window are written at presentation, not at decision: an offer decided but never shown (a reconnect started, or the user opened the paywall) must not spend its one chance.
    private func armOffer(
        _ reason: SessionOfferPolicy.Reason,
        consuming: SessionOfferPolicy.Consumption
    ) {
        pendingOffer = Task { [weak self] in
            // Cleared on every exit: a task left armed behind a failed guard would block the next real offer for the life of the app.
            defer { self?.pendingOffer = nil }

            try? await Task.sleep(for: .seconds(SessionOfferPolicy.offerAfterSessionDelay))

            // A session being put back is not an ending worth selling at.
            guard let self, !Task.isCancelled, !phase.holdsSession, paywallReason == nil,
                  !sessions.contains(where: \.isBeingPutBack) else {
                return
            }
            switch consuming {
            case .firstSession: hasOfferedAfterFirstSession = true
            case .lowAllowance: lowRelayOfferWindow = relayWindowNumber
            }
            paywallReason = Self.paywallReason(for: reason)
        }
    }

    /// A mapping rather than a shared enum: the policy decides, ``PaywallView`` chooses words, and those live in a view this module cannot follow.
    private static func paywallReason(for reason: SessionOfferPolicy.Reason) -> PaywallView.Reason {
        switch reason {
        case .firstSession: return .firstSession
        case .runningLow(let remaining): return .runningLow(remaining: remaining)
        case .quotaExhausted: return .quotaExhausted
        }
    }
}
