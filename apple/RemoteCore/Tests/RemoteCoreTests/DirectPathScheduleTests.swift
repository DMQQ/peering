import Testing

@testable import RemoteCore

@Suite("Direct path schedule")
struct DirectPathScheduleTests {
    private let start = ContinuousClock.now

    @Test("it knocks fast at first and slows down after twelve attempts")
    func fastThenSlow() {
        var schedule = DirectPathSchedule(now: start)
        #expect(schedule.intervalToNextProbe == DirectPathSchedule.fastInterval)
        for _ in 0..<12 { schedule.probeSent() }
        #expect(schedule.intervalToNextProbe == DirectPathSchedule.fastInterval, "the twelfth probe is still followed by a fast wait")
        schedule.probeSent()
        #expect(schedule.intervalToNextProbe == DirectPathSchedule.slowInterval)
    }

    @Test("it asks the relay at once, then once every twelve attempts")
    func asksTheRelayOnACadence() {
        var schedule = DirectPathSchedule(now: start)
        #expect(schedule.asksRelayForPeerAddress)
        var asks = 0
        for _ in 0..<36 {
            schedule.probeSent()
            if schedule.asksRelayForPeerAddress { asks += 1 }
        }
        #expect(asks == 3)
    }

    @Test("the verdict is measured from the start of the attempt")
    func verdictFromStart() {
        let schedule = DirectPathSchedule(now: start)
        #expect(!schedule.verdictIsDue(now: start + .seconds(7)))
        #expect(schedule.verdictIsDue(now: start + .seconds(8)))
    }

    @Test("a restart knocks fast again, asks the relay at once and gives the new attempt its own time")
    func restartResetsEverything() {
        var schedule = DirectPathSchedule(now: start)
        for _ in 0..<20 { schedule.probeSent() }
        #expect(schedule.intervalToNextProbe == DirectPathSchedule.slowInterval)
        #expect(schedule.verdictIsDue(now: start + .seconds(30)))

        schedule.restart(now: start + .seconds(30))

        #expect(schedule.asksRelayForPeerAddress)
        #expect(schedule.intervalToNextProbe == DirectPathSchedule.fastInterval)
        #expect(!schedule.verdictIsDue(now: start + .seconds(35)))
        #expect(schedule.verdictIsDue(now: start + .seconds(38)))
    }
}
