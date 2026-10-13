import Testing
@testable import MacCastKit

struct OutboundBackPressureTests {
    @Test func theGateClosesAtFourMegabytesAndOpensBelowOne() {
        var pressure = OutboundBackPressure()
        let result1 = pressure.queued(3_000_000)
        #expect(result1 == nil)
        let result2 = pressure.queued(1_500_000)
        #expect(result2 == .backedUp)
        let result3 = pressure.queued(100)
        #expect(result3 == nil)
        let result4 = pressure.completed(2_000_000)
        #expect(result4 == nil)
        #expect(pressure.isBackedUp)
        let result5 = pressure.completed(2_000_000)
        #expect(result5 == .drained)
        #expect(!pressure.isBackedUp)
    }

    @Test func completionsNeverDriveTheCountNegative() {
        var pressure = OutboundBackPressure()
        _ = pressure.queued(10)
        _ = pressure.completed(1_000)
        #expect(pressure.inFlightBytes == 0)
    }
}

struct HeldEventQueueTests {
    @Test func eventsComeBackOldestFirstAndTheQueueEmpties() {
        var queue = HeldEventQueue<Int>(maximumBytes: 100)
        queue.append(1, cost: 10)
        queue.append(2, cost: 10)
        let result6 = queue.drain()
        #expect(result6 == [1, 2])
        #expect(queue.isEmpty)
    }

    @Test func overflowDropsTheOldestAndKeepsTheNewest() {
        var queue = HeldEventQueue<Int>(maximumBytes: 25)
        queue.append(1, cost: 10)
        queue.append(2, cost: 10)
        queue.append(3, cost: 10)
        #expect(queue.droppedCount == 1)
        let result7 = queue.drain()
        #expect(result7 == [2, 3])
    }

    @Test func oneEventLargerThanTheLimitIsStillKept() {
        var queue = HeldEventQueue<Int>(maximumBytes: 5)
        queue.append(9, cost: 50)
        let result8 = queue.drain()
        #expect(result8 == [9])
    }
}
