import Foundation
import PeeringKit
import RemoteCore

/// Asks for an App Store rating on the teardown of a session, after several real sessions over several days. The rule is ``PeeringKit/ReviewPromptPolicy``; the system decides whether the prompt actually appears.
extension SessionModel {
    private var reviewTally: ReviewPromptPolicy.Tally {
        get {
            UserDefaults.standard.data(forKey: PreferenceKeys.reviewPromptTally)
                .flatMap { try? JSONDecoder().decode(ReviewPromptPolicy.Tally.self, from: $0) }
                ?? ReviewPromptPolicy.Tally()
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: PreferenceKeys.reviewPromptTally)
        }
    }

    func askForReviewIfDue(after record: ClientSessionRecord) {
        var tally = reviewTally
        tally.record(sessionDuration: record.duration, at: record.endedAt)
        reviewTally = tally
        guard isReviewDue(tally) else { return }

        pendingReviewPrompt = Task { [weak self] in
            defer { self?.pendingReviewPrompt = nil }
            try? await Task.sleep(for: .seconds(ReviewPromptPolicy.askAfterSessionDelay))
            guard let self, !Task.isCancelled, !phase.holdsSession else { return }
            var tally = reviewTally
            // Asked again here: the subscription offer decided at the same teardown has had time to open its paywall by now.
            guard isReviewDue(tally) else { return }
            tally.lastAskedAt = Date()
            reviewTally = tally
            wantsReviewPrompt = true
        }
    }

    private func isReviewDue(_ tally: ReviewPromptPolicy.Tally) -> Bool {
        ReviewPromptPolicy.isDue(
            tally,
            hasPaywallOpen: paywallReason != nil,
            hasPendingOffer: pendingOffer != nil,
            now: Date()
        )
    }
}
