import Foundation
import Testing

@testable import MacCastKit

@Suite("Warning about a very bad connection")
struct BadConnectionWarningTests {
    private let start = ContinuousClock.Instant.now

    @Test("a single slow reading says nothing")
    func oneSlowReading() {
        var warning = BadConnectionWarning()
        let r1 = warning.shouldWarn(milliseconds: 1500, now: start)
        #expect(!r1)
    }

    @Test("three slow readings in a row warn once")
    func sustainedSlowReadings() {
        var warning = BadConnectionWarning()
        let r2 = warning.shouldWarn(milliseconds: 1200, now: start)
        #expect(!r2)
        let r3 = warning.shouldWarn(milliseconds: 1300, now: start)
        #expect(!r3)
        let r4 = warning.shouldWarn(milliseconds: 1400, now: start)
        #expect(r4)
        let r5 = warning.shouldWarn(milliseconds: 1400, now: start)
        #expect(!r5)
    }

    @Test("a good reading in between starts the count again")
    func recoveryResetsTheCount() {
        var warning = BadConnectionWarning()
        let r6 = warning.shouldWarn(milliseconds: 1200, now: start)
        #expect(!r6)
        let r7 = warning.shouldWarn(milliseconds: 1200, now: start)
        #expect(!r7)
        let r8 = warning.shouldWarn(milliseconds: 200, now: start)
        #expect(!r8)
        let r9 = warning.shouldWarn(milliseconds: 1200, now: start)
        #expect(!r9)
    }

    @Test("999 milliseconds is not bad enough, 1000 is")
    func theThreshold() {
        var warning = BadConnectionWarning()
        var early: [Bool] = []
        for _ in 0..<5 { early.append(warning.shouldWarn(milliseconds: 999, now: start)) }
        #expect(!early.contains(true))
        let r10 = warning.shouldWarn(milliseconds: 1000, now: start)
        #expect(!r10)
        let r11 = warning.shouldWarn(milliseconds: 1000, now: start)
        #expect(!r11)
        let r12 = warning.shouldWarn(milliseconds: 1000, now: start)
        #expect(r12)
    }

    @Test("it warns again after the cooldown if the connection is still bad")
    func warnsAgainAfterCooldown() {
        var warning = BadConnectionWarning()
        for _ in 0..<3 { _ = warning.shouldWarn(milliseconds: 2000, now: start) }
        let later = start + .seconds(BadConnectionWarning.cooldown + 1)
        let r13 = warning.shouldWarn(milliseconds: 2000, now: later)
        #expect(r13)
    }
}
