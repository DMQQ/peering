import Testing
@testable import PeeringKit

struct BackgroundRedialTests {
    @Test func theTimerDialsWhileTheAppIsInFront() {
        #expect(BackgroundRedial.mayDialFromTimer(appIsBackground: false, pictureInPictureIsActive: false))
    }

    @Test func theTimerWaitsForTheAppWhenItIsAwayWithNoWindow() {
        #expect(!BackgroundRedial.mayDialFromTimer(appIsBackground: true, pictureInPictureIsActive: false))
    }

    @Test func theTimerKeepsDialingUnderAFloatingWindow() {
        #expect(BackgroundRedial.mayDialFromTimer(appIsBackground: true, pictureInPictureIsActive: true))
    }
}
