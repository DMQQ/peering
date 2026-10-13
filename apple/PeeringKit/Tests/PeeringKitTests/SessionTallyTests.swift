import Testing
@testable import PeeringKit

struct SessionTallyTests {
    @Test func stretchesAddUpAcrossADrop() {
        var tally = SessionTally()
        tally.addStretch(seconds: 50.4, videoBytes: 2_000_000, droppedFrames: 3)
        tally.noteReconnect()
        tally.addStretch(seconds: 10, videoBytes: 500_000, droppedFrames: 0)
        #expect(tally.seconds == 60)
        #expect(tally.videoBytes == 2_500_000)
        #expect(tally.droppedFrames == 3)
        #expect(tally.reconnects == 1)
    }

    @Test func aNegativeFigureIsNotSubtracted() {
        var tally = SessionTally()
        tally.addStretch(seconds: -5, videoBytes: -1, droppedFrames: -2)
        #expect(tally == SessionTally())
    }
}
