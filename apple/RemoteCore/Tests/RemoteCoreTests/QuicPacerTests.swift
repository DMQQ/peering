import Foundation
import Testing

@testable import RemoteCore

struct QuicPacerTests {
    private func packet(_ byte: UInt8, after milliseconds: Int) -> QuicConnection.Packet {
        .init(bytes: Data([byte]), destination: QuicAddress(host: "127.0.0.1", port: 1)!, delay: .milliseconds(milliseconds))
    }

    @Test("packets are written in order, each no earlier than quiche asked")
    func writesInOrderAtTheirTimes() async {
        let queue = DispatchQueue(label: "test.pacer")
        let written = Written()
        let started = DispatchTime.now()
        let pacer = QuicPacer(queue: queue) { written.add($0.bytes[0], at: DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) }
        queue.sync { pacer.submit([packet(1, after: 0), packet(2, after: 30), packet(3, after: 60)]) }
        let deadline = Date().addingTimeInterval(2)
        while written.count < 3, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        let log = written.entries
        #expect(log.map(\.byte) == [1, 2, 3])
        #expect(log[0].nanoseconds < 10_000_000, "a packet due now goes at once")
        #expect(log[1].nanoseconds >= 29_000_000)
        #expect(log[2].nanoseconds >= 59_000_000)
        _ = pacer
    }
}

private final class Written: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(byte: UInt8, nanoseconds: UInt64)] = []
    func add(_ byte: UInt8, at nanoseconds: UInt64) { lock.withLock { log.append((byte, nanoseconds)) } }
    var count: Int { lock.withLock { log.count } }
    var entries: [(byte: UInt8, nanoseconds: UInt64)] { lock.withLock { log } }
}
