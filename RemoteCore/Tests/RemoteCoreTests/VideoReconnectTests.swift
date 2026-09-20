import Foundation
import Testing

@testable import RemoteCore

/// The rule that decides when a client stops asking for its picture back.
///
/// **Every interesting case here is about timing**, which is why the ladder is a value with a
/// clock-free entry point rather than a loop inside `ClientSession`: a test that had to wait out
/// fourteen seconds to see the fifth rung would be a test nobody runs.
@Suite("Reopening the video socket")
struct VideoReconnectLadderTests {
    @Test("the waits are handed out in order and then there are none")
    func rungsAreHandedOutInOrder() {
        var ladder = VideoReconnectLadder()

        // Asked once per rung, and compacted so the comparison below is between two lists of
        // waits: a rung that answered nothing would show up as a shorter list rather than as a
        // hole the equality could miss.
        let waits = (0..<VideoReconnectLadder.delays.count).compactMap { _ in ladder.next() }

        #expect(waits == VideoReconnectLadder.delays)
        // The answer after the last rung, and the one the client acts on: no more attempts, and
        // the session is told the picture is not coming back rather than left waiting for it.
        #expect(ladder.next() == nil)
        #expect(ladder.isSpent)
    }

    @Test("a fresh ladder is not spent, and a spent one starts again when reset")
    func resetReturnsToTheFirstRung() {
        var ladder = VideoReconnectLadder()
        #expect(!ladder.isSpent)

        while ladder.next() != nil {}
        #expect(ladder.isSpent)

        // Recovery is the only thing that does this, so what it has to guarantee is that the next
        // failure gets the whole ladder again rather than the last rung of the previous one.
        ladder.reset()
        #expect(!ladder.isSpent)
        #expect(ladder.attempts == 0)
        #expect(ladder.next() == VideoReconnectLadder.delays[0])
    }

    @Test("the first wait is short and the others never shrink")
    func waitsAreShortFirstAndNeverShrink() {
        // Half a second is the difference between a picture that stutters and a picture that is
        // gone, so the first rung is the one number here worth asserting on directly.
        #expect(VideoReconnectLadder.delays.first == Duration.milliseconds(500))
        #expect(VideoReconnectLadder.delays == VideoReconnectLadder.delays.sorted())
        // A ladder that can be asked forever is a client that dials a Mac which will not answer
        // until somebody stops it.
        #expect(VideoReconnectLadder.delays.count <= 8)
    }
}
