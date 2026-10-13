import Testing
import RemoteCore
@testable import PeeringKit

struct DropStreakTests {
    private func drop(_ streak: inout DropStreak, _ reason: ClientSession.FailureReason = .unresponsive, ran: Double = 50, picture: Double = 20) -> DropStreak.Verdict {
        streak.sessionEnded(reason: reason, ranSeconds: ran, pictureSeconds: picture)
    }

    @Test func twoSilentDropsAreRetriedAndTheThirdStops() {
        var streak = DropStreak()
        #expect(drop(&streak) == .retry)
        #expect(drop(&streak, .transport) == .retry)
        #expect(drop(&streak) == .stop)
    }

    @Test func aSessionThatRanTwoMinutesBreaksTheStreak() {
        var streak = DropStreak()
        _ = drop(&streak)
        _ = drop(&streak)
        #expect(drop(&streak, ran: 120) == .retry)
        #expect(streak.count == 0)
    }

    @Test func aSessionThatKeptAPictureForAMinuteBreaksTheStreak() {
        var streak = DropStreak()
        _ = drop(&streak)
        _ = drop(&streak)
        #expect(drop(&streak, ran: 90, picture: 60) == .retry)
        #expect(streak.count == 0)
    }

    @Test func anEndingThatIsNotSilentBreaksTheStreak() {
        var streak = DropStreak()
        _ = drop(&streak)
        _ = drop(&streak)
        #expect(drop(&streak, .hostClosed) == .retry)
        #expect(streak.count == 0)
    }

    @Test func aManualConnectStartsOver() {
        var streak = DropStreak(count: 2)
        streak.reset()
        #expect(drop(&streak) == .retry)
        #expect(streak.count == 1)
    }

    @Test func theCheckedFormOfUnresponsiveCounts() {
        var streak = DropStreak(count: 2)
        #expect(drop(&streak, .unresponsiveAfterCheck) == .stop)
    }

    @Test func pictureTimeRunsFromTheFirstPictureToTheLast() {
        #expect(DropStreak.pictureSeconds(ranSeconds: 100, firstPictureMilliseconds: 2000, lastFrameAgeMilliseconds: 8000) == 90)
        #expect(DropStreak.pictureSeconds(ranSeconds: 100, firstPictureMilliseconds: nil, lastFrameAgeMilliseconds: nil) == 0)
        #expect(DropStreak.pictureSeconds(ranSeconds: 5, firstPictureMilliseconds: 4000, lastFrameAgeMilliseconds: 3000) == 0)
    }
}
