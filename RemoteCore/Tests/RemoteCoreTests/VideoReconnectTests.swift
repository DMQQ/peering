import Foundation
import Testing

@testable import RemoteCore

/// The ladder is a value with a clock-free entry point so a test need not wait out fourteen seconds.
@Suite("Reopening the video socket")
struct VideoReconnectLadderTests {
    @Test("the waits are handed out in order and then there are none")
    func rungsAreHandedOutInOrder() {
        var ladder = VideoReconnectLadder()

        let waits = (0..<VideoReconnectLadder.delays.count).compactMap { _ in ladder.next() }

        #expect(waits == VideoReconnectLadder.delays)
        #expect(ladder.next() == nil)
        #expect(ladder.isSpent)
    }

    @Test("a fresh ladder is not spent, and a spent one starts again when reset")
    func resetReturnsToTheFirstRung() {
        var ladder = VideoReconnectLadder()
        #expect(!ladder.isSpent)

        while ladder.next() != nil {}
        #expect(ladder.isSpent)

        ladder.reset()
        #expect(!ladder.isSpent)
        #expect(ladder.attempts == 0)
        #expect(ladder.next() == VideoReconnectLadder.delays[0])
    }

    @Test("the first wait is short and the others never shrink")
    func waitsAreShortFirstAndNeverShrink() {
        #expect(VideoReconnectLadder.delays.first == Duration.milliseconds(500))
        #expect(VideoReconnectLadder.delays == VideoReconnectLadder.delays.sorted())
        #expect(VideoReconnectLadder.delays.count <= 8)
    }
}
