import Foundation
import Testing

@testable import RemoteCore

struct PacingBacklogTests {
    private func datagrams(_ count: Int, tag: UInt8) -> [Data] {
        (0..<count).map { Data([tag, UInt8($0)]) }
    }

    @Test("a large entry leaves in bursts no bigger than the limit")
    func bursts() {
        var backlog = PacingBacklog<String>()
        backlog.append(datagrams(10, tag: 1), entry: "a")
        var sizes: [Int] = []
        while let burst = backlog.nextBurst(limit: 4) { sizes.append(burst.datagrams.count) }
        #expect(sizes == [4, 4, 2])
        #expect(backlog.isEmpty)
    }

    @Test("a later entry never overtakes the tail of an earlier one")
    func order() {
        var backlog = PacingBacklog<String>()
        backlog.append(datagrams(5, tag: 1), entry: "a")
        backlog.append(datagrams(2, tag: 2), entry: "b")
        var tags: [UInt8] = []
        while let burst = backlog.nextBurst(limit: 3) { tags += burst.datagrams.map { $0[0] } }
        #expect(tags == [1, 1, 1, 1, 1, 2, 2])
    }

    @Test("only the last burst of an entry finishes it")
    func finishing() {
        var backlog = PacingBacklog<String>()
        backlog.append(datagrams(5, tag: 1), entry: "a")
        #expect(backlog.nextBurst(limit: 3)?.finishesEntry == false)
        #expect(backlog.nextBurst(limit: 3)?.finishesEntry == true)
        #expect(backlog.nextBurst(limit: 3) == nil)
    }

    @Test("stopping hands back every entry still waiting")
    func removal() {
        var backlog = PacingBacklog<String>()
        backlog.append(datagrams(5, tag: 1), entry: "a")
        backlog.append(datagrams(1, tag: 2), entry: "b")
        _ = backlog.nextBurst(limit: 2)
        #expect(backlog.removeAll() == ["a", "b"])
        #expect(backlog.isEmpty)
    }
}
