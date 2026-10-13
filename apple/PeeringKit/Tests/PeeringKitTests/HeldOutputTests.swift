import Testing

@testable import PeeringKit

struct HeldOutputTests {
    private typealias Output = HeldOutput<String, Int>

    @Test func anOpenQueueSendsEverythingAtOnce() {
        var output = Output()
        let sendNow = output.offer(1, key: "a", index: 1)
        #expect(sendNow)
    }

    @Test func aPausedQueueHoldsEventsInOrderAndReleasesThemOnResume() {
        var output = Output()
        output.pause()
        let first = output.offer(1, key: "a", index: 1)
        let second = output.offer(2, key: "a", index: 2)
        let batch = output.resume()
        #expect(!first && !second)
        #expect(batch.events == [1, 2])
        #expect(batch.resync.isEmpty)
    }

    @Test func eventsThatArriveWhileTheBatchGoesOutAreHeldBehindIt() {
        var output = Output()
        output.pause()
        _ = output.offer(1, key: "a", index: 1)
        _ = output.resume()
        let late = output.offer(2, key: "a", index: 2)
        let more = output.finishedDraining()
        let done = output.finishedDraining()
        let after = output.offer(3, key: "a", index: 3)
        #expect(!late)
        #expect(more?.events == [2])
        #expect(done == nil)
        #expect(after)
    }

    @Test func pastTheCapEventsAreDroppedAndTheirSessionsAreMarkedForAReplay() {
        var output = Output(capacity: 2)
        output.pause()
        _ = output.offer(1, key: "a", index: 5)
        _ = output.offer(2, key: "b", index: 9)
        let dropped = output.offer(3, key: "a", index: 6)
        let batch = output.resume()
        #expect(!dropped)
        #expect(batch.events.isEmpty)
        #expect(batch.resync == ["a": 4, "b": 8])
    }

    @Test func aSessionMarkedForAReplayHoldsNothingMoreUntilResumed() {
        var output = Output(capacity: 1)
        output.pause()
        _ = output.offer(1, key: "a", index: 1)
        _ = output.offer(2, key: "a", index: 2)
        let third = output.offer(3, key: "a", index: 3)
        let batch = output.resume()
        #expect(!third)
        #expect(batch.resync == ["a": 0])
    }

    @Test func aQueuePausedAgainWhileDrainingStaysClosedToLiveEvents() {
        var output = Output()
        output.pause()
        _ = output.resume()
        output.pause()
        let more = output.finishedDraining()
        let live = output.offer(1, key: "a", index: 1)
        #expect(more == nil)
        #expect(!live)
    }

    @Test func resumingAnOpenQueueDoesNothing() {
        var output = Output()
        let batch = output.resume()
        #expect(batch.isEmpty)
        #expect(!output.isHolding)
    }
}
