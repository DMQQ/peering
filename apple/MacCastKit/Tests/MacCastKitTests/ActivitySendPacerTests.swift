import Foundation
import Testing

@testable import MacCastKit

struct ActivitySendPacerTests {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    @Test func theFirstSendToATokenIsImmediate() {
        var pacer = ActivitySendPacer()
        #expect(pacer.delay(for: "a", now: t0) == 0)
    }

    @Test func aSecondSendWithinTheGapWaitsForTheRestOfIt() {
        var pacer = ActivitySendPacer()
        _ = pacer.delay(for: "a", now: t0)
        #expect(pacer.delay(for: "a", now: t0.addingTimeInterval(0.25)) == 0.75)
    }

    @Test func sendsQueuedTogetherLeaveOneGapApartInOrder() {
        var pacer = ActivitySendPacer()
        let delays = (0..<3).map { _ in pacer.delay(for: "a", now: t0) }
        #expect(delays == [0, 1, 2])
    }

    @Test func otherTokensAreNotHeldBack() {
        var pacer = ActivitySendPacer()
        _ = pacer.delay(for: "a", now: t0)
        #expect(pacer.delay(for: "b", now: t0) == 0)
    }

    @Test func aSendAfterTheGapIsImmediateAgain() {
        var pacer = ActivitySendPacer()
        _ = pacer.delay(for: "a", now: t0)
        #expect(pacer.delay(for: "a", now: t0.addingTimeInterval(1.5)) == 0)
    }

    @Test func clearingForgetsTheReservedSlots() {
        var pacer = ActivitySendPacer()
        _ = pacer.delay(for: "a", now: t0)
        pacer.clear()
        #expect(pacer.delay(for: "a", now: t0) == 0)
    }
}
