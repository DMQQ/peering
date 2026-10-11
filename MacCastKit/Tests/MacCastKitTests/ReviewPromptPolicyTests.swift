import Foundation
import Testing
@testable import MacCastKit

struct ReviewPromptPolicyTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func tally(sessions: Int, firstAt: Date?, askedAt: Date? = nil) -> ReviewPromptPolicy.Tally {
        var tally = ReviewPromptPolicy.Tally()
        tally.qualifyingSessions = sessions
        tally.firstQualifyingAt = firstAt
        tally.lastAskedAt = askedAt
        return tally
    }

    private func isDue(_ tally: ReviewPromptPolicy.Tally, paywall: Bool = false, pending: Bool = false, after days: Double) -> Bool {
        ReviewPromptPolicy.isDue(tally, hasPaywallOpen: paywall, hasPendingOffer: pending, now: start.addingTimeInterval(days * day))
    }

    @Test func shortSessionsDoNotCount() {
        var tally = ReviewPromptPolicy.Tally()
        tally.record(sessionDuration: 119, at: start)
        #expect(tally.qualifyingSessions == 0)
        #expect(tally.firstQualifyingAt == nil)
    }

    @Test func aLongSessionCountsAndFixesTheFirstDate() {
        var tally = ReviewPromptPolicy.Tally()
        tally.record(sessionDuration: 120, at: start)
        tally.record(sessionDuration: 600, at: start.addingTimeInterval(day))
        #expect(tally.qualifyingSessions == 2)
        #expect(tally.firstQualifyingAt == start)
    }

    @Test func dueOnceEnoughSessionsHaveSpanEnoughDays() {
        #expect(isDue(tally(sessions: 3, firstAt: start), after: 3))
    }

    @Test func notDueWithTooFewSessions() {
        #expect(!isDue(tally(sessions: 2, firstAt: start), after: 30))
    }

    @Test func notDueWhenAllSessionsAreRecent() {
        #expect(!isDue(tally(sessions: 5, firstAt: start), after: 2))
    }

    @Test func notDueAgainInsideTheCooldown() {
        #expect(!isDue(tally(sessions: 9, firstAt: start, askedAt: start.addingTimeInterval(10 * day)), after: 100))
    }

    @Test func dueAgainAfterTheCooldown() {
        #expect(isDue(tally(sessions: 9, firstAt: start, askedAt: start.addingTimeInterval(10 * day)), after: 131))
    }

    @Test func neverOverAPaywallOrAPendingOffer() {
        let ready = tally(sessions: 5, firstAt: start)
        #expect(!isDue(ready, paywall: true, after: 30))
        #expect(!isDue(ready, pending: true, after: 30))
    }
}
