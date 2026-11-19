import Testing
@testable import PeeringKit

struct AudioSendQueueTests {
    @Test func framesLeaveInTheOrderTheyArrived() {
        var queue = AudioSendQueue<Int>()
        queue.push(1)
        queue.push(2)
        #expect(queue.popForTurn(pictureWaiting: false) == 1)
        #expect(queue.popForTurn(pictureWaiting: false) == 2)
        #expect(queue.popForTurn(pictureWaiting: false) == nil)
    }

    @Test func aFullQueueDropsTheOldestFrame() {
        var queue = AudioSendQueue<Int>(capacity: 2)
        queue.push(1)
        queue.push(2)
        let dropped = queue.push(3)
        #expect(dropped)
        #expect(queue.popForTurn(pictureWaiting: false) == 2)
        #expect(queue.popForTurn(pictureWaiting: false) == 3)
    }

    @Test func aWaitingPictureGetsATurnAfterABurst() {
        var queue = AudioSendQueue<Int>(capacity: 16, burst: 2)
        queue.reset()
        for frame in 1...5 { queue.push(frame) }
        // The picture goes first after a reset, then two frames, then the picture again.
        #expect(queue.popForTurn(pictureWaiting: true) == nil)
        #expect(queue.popForTurn(pictureWaiting: true) == 1)
        #expect(queue.popForTurn(pictureWaiting: true) == 2)
        #expect(queue.popForTurn(pictureWaiting: true) == nil)
        #expect(queue.popForTurn(pictureWaiting: true) == 3)
    }

    @Test func audioIsNeverHeldBackWhenNoPictureIsWaiting() {
        var queue = AudioSendQueue<Int>(capacity: 16, burst: 1)
        for frame in 1...4 { queue.push(frame) }
        let sent = (0..<4).compactMap { _ in queue.popForTurn(pictureWaiting: false) }
        #expect(sent == [1, 2, 3, 4])
    }
}
