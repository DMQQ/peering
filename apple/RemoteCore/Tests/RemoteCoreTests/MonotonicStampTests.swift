import Foundation
import Testing
@testable import RemoteCore

@Suite("Monotonic stamp")
struct MonotonicStampTests {
    private let start = ContinuousClock.Instant.now

    @Test("a stamp is within a limit until the limit has passed")
    func withinUntilTheLimit() {
        let stamp = MonotonicStamp(start)
        #expect(stamp.isWithin(seconds: 60, at: start + .seconds(59)))
        #expect(!stamp.isWithin(seconds: 60, at: start + .seconds(60)))
        #expect(!stamp.isWithin(seconds: 60, at: start + .seconds(61)))
    }

    @Test("elapsed time is the distance between the stamp and now")
    func elapsed() {
        let stamp = MonotonicStamp(start)
        #expect(stamp.elapsed(at: start + .milliseconds(1_500)) == .milliseconds(1_500))
        #expect(stamp.elapsedSeconds(at: start + .milliseconds(1_500)) == 1.5)
    }

    @Test("a stamp taken at the same moment has no elapsed time")
    func zeroElapsed() {
        #expect(MonotonicStamp(start).elapsed(at: start) == .zero)
    }
}
