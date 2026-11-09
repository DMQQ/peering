import Foundation
import Testing

@testable import PeeringKit

@Suite("Keyframe wait")
struct KeyframeWaitTests {
    private let t0 = ContinuousClock.now

    @Test("a keyframe that arrives at once is reported with how long it took")
    func reportsTheWait() {
        var wait = KeyframeWait()
        wait.asked(at: t0)
        let delivered = wait.delivered(at: t0 + .milliseconds(40))
        #expect(delivered == .init(waitedMilliseconds: 40, nudged: false))
    }

    @Test("a keyframe nobody asked for is not reported")
    func periodicKeyframe() {
        var wait = KeyframeWait()
        let delivered = wait.delivered(at: t0)
        #expect(delivered == nil)
    }

    @Test("a second ask does not restart the wait")
    func earliestAskCounts() {
        var wait = KeyframeWait()
        wait.asked(at: t0)
        wait.asked(at: t0 + .milliseconds(100))
        let delivered = wait.delivered(at: t0 + .milliseconds(300))
        #expect(delivered?.waitedMilliseconds == 300)
    }

    @Test("a still screen is nudged once, after the delay and not before")
    func nudgesOnce() {
        var wait = KeyframeWait()
        wait.asked(at: t0)
        let early = wait.shouldNudge(at: t0 + .milliseconds(149))
        let due = wait.shouldNudge(at: t0 + .milliseconds(150))
        let again = wait.shouldNudge(at: t0 + .milliseconds(900))
        #expect(!early)
        #expect(due)
        #expect(!again)
    }

    @Test("a nudged wait says so when it ends, and the next wait starts clean")
    func nudgeIsRemembered() {
        var wait = KeyframeWait()
        wait.asked(at: t0)
        _ = wait.shouldNudge(at: t0 + .milliseconds(200))
        let first = wait.delivered(at: t0 + .milliseconds(260))
        wait.asked(at: t0 + .seconds(5))
        let second = wait.delivered(at: t0 + .seconds(5) + .milliseconds(10))
        #expect(first == .init(waitedMilliseconds: 260, nudged: true))
        #expect(second == .init(waitedMilliseconds: 10, nudged: false))
    }

    @Test("nothing is nudged when nothing was asked for")
    func noAskNoNudge() {
        var wait = KeyframeWait()
        let nudge = wait.shouldNudge(at: t0 + .seconds(10))
        #expect(!nudge)
    }
}
