import Foundation
import Testing

@testable import RemoteCore

struct DatagramLossMeterTests {
    @Test("nothing arriving says nothing")
    func silent() {
        var meter = DatagramLossMeter()
        #expect(meter.sample() == nil)
    }

    @Test("a clean run reads as no loss")
    func clean() {
        var meter = DatagramLossMeter()
        for counter in 0..<100 { meter.note(counter: UInt64(counter)) }
        #expect(meter.sample() == 0)
    }

    @Test("every tenth datagram missing reads as ten percent")
    func tenPercent() {
        var meter = DatagramLossMeter()
        for counter in 1...100 where counter % 10 != 0 { meter.note(counter: UInt64(counter)) }
        meter.note(counter: 101)
        let loss = meter.sample()
        #expect(loss != nil)
        #expect(abs((loss ?? 0) - 0.1) < 0.001)
    }

    @Test("reordering is not loss")
    func reordered() {
        var meter = DatagramLossMeter()
        for counter in [3, 1, 2, 5, 4] { meter.note(counter: UInt64(counter)) }
        #expect(meter.sample() == 0)
    }

    @Test("each sample covers only the interval since the last")
    func intervals() {
        var meter = DatagramLossMeter()
        for counter in 0..<10 where counter != 4 { meter.note(counter: UInt64(counter)) }
        #expect((meter.sample() ?? 0) > 0)
        for counter in 10..<20 { meter.note(counter: UInt64(counter)) }
        #expect(meter.sample() == 0)
        #expect(meter.sample() == nil)
    }
}
