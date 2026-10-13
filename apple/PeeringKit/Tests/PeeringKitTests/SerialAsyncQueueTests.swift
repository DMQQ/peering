import Testing
@testable import PeeringKit

struct SerialAsyncQueueTests {
    private actor Link {
        private(set) var sent: [Int] = []
        func send(_ value: Int, slow: Bool) async {
            if slow { for _ in 0..<50 { await Task.yield() } }
            sent.append(value)
        }
    }

    @Test func aSlowSendDoesNotLetALaterOneOvertakeIt() async {
        let link = Link()
        let (done, finished) = AsyncStream.makeStream(of: Void.self)
        let queue = SerialAsyncQueue<Int> { value in
            await link.send(value, slow: value == 1)
            if value == 3 { finished.yield() }
        }
        for value in 1...3 { queue.enqueue(value) }
        for await _ in done { break }
        #expect(await link.sent == [1, 2, 3])
    }

    @Test func enqueuedElementsStillRunAfterFinish() async {
        let link = Link()
        let (done, finished) = AsyncStream.makeStream(of: Void.self)
        let queue = SerialAsyncQueue<Int> { value in
            await link.send(value, slow: false)
            if value == 2 { finished.yield() }
        }
        queue.enqueue(1)
        queue.enqueue(2)
        queue.finish()
        queue.enqueue(3)
        for await _ in done { break }
        #expect(await link.sent == [1, 2])
    }
}
