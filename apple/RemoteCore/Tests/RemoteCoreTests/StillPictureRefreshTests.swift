import Testing

@testable import RemoteCore

struct StillPictureRefreshTests {
    @Test func theFirstRepeatWaitsForStillnessAndLaterOnesFollowQuickly() {
        #expect(StillPictureRefresh.delayMilliseconds(beforeRepeat: 0) == 150)
        #expect(StillPictureRefresh.delayMilliseconds(beforeRepeat: 1) == 33)
        #expect(StillPictureRefresh.delayMilliseconds(beforeRepeat: 7) == 33)
    }

    @Test func theSequenceEndsAfterTheLastRepeat() {
        #expect(StillPictureRefresh.delayMilliseconds(beforeRepeat: 8) == nil)
        #expect(StillPictureRefresh.delayMilliseconds(beforeRepeat: -1) == nil)
    }
}
