import Foundation
import Testing
@testable import RemoteCore

/// Two transports whose carriers hand each other's bytes across, with the lane switchable and droppable.
private final class Duplex: @unchecked Sendable {
    private let lock = NSLock()
    private var _laneLive = false
    private var _dropLane = false
    private var _atB: [Frame] = []
    private var _atA: [Frame] = []
    var a: StreamTransport!
    var b: StreamTransport!

    var laneLive: Bool {
        get { lock.withLock { _laneLive } }
        set { lock.withLock { _laneLive = newValue } }
    }
    var dropLane: Bool {
        get { lock.withLock { _dropLane } }
        set { lock.withLock { _dropLane = newValue } }
    }
    var atB: [Frame] { lock.withLock { _atB } }
    var atA: [Frame] { lock.withLock { _atA } }

    init() {
        a = StreamTransport(queue: DispatchQueue(label: "test.a"), hooks: hooks(toB: true))
        b = StreamTransport(queue: DispatchQueue(label: "test.b"), hooks: hooks(toB: false))
        a.start()
        b.start()
    }

    private func hooks(toB: Bool) -> StreamTransport.Hooks {
        StreamTransport.Hooks(
            sendOnControl: { [unowned self] payload in (toB ? b : a).receive(payload) },
            sendOnLane: { [unowned self] payload in
                guard !dropLane else { return }
                (toB ? b : a).receive(payload)
            },
            laneIsLive: { [unowned self] in laneLive },
            deliver: { [unowned self] frame in lock.withLock { if toB { _atA.append(frame) } else { _atB.append(frame) } } },
            fail: { _ in }
        )
    }

    func waitFor(_ condition: () -> Bool, seconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    func stop() {
        a.stop()
        b.stop()
    }
}

struct StreamTransportTests {
    private func command(_ number: Int) -> Frame { Frame(kind: .command, payload: Data("command \(number)".utf8)) }

    @Test func framesCrossTheControlConnectionWhenTheLaneIsDown() async {
        let link = Duplex()
        defer { link.stop() }
        for number in 0..<20 { link.a.send(command(number)) }
        let done = await link.waitFor { link.atB.count == 20 }
        #expect(done)
        #expect(link.atB == (0..<20).map(command))
    }

    @Test func framesCrossTheLaneOnceItIsLive() async {
        let link = Duplex()
        defer { link.stop() }
        link.laneLive = true
        for number in 0..<20 { link.a.send(command(number)) }
        let done = await link.waitFor { link.atB.count == 20 }
        #expect(done)
        #expect(link.atB == (0..<20).map(command))
    }

    @Test func aLaneThatStopsCarryingIsLeftWithoutLosingAFrame() async {
        let link = Duplex()
        defer { link.stop() }
        link.laneLive = true
        link.dropLane = true
        for number in 0..<10 { link.a.send(command(number)) }
        // Nothing arrives while the lane eats everything, then the transport gives up on it.
        let done = await link.waitFor({ link.atB.count == 10 }, seconds: 15)
        #expect(done)
        #expect(link.atB == (0..<10).map(command))
    }

    @Test func aFrameThatNeverTravelsOnAStreamIsLeftToTheCaller() {
        let link = Duplex()
        defer { link.stop() }
        #expect(!link.a.send(Frame(kind: .videoFrame, payload: Data([1]))))
    }

    @Test func aCompletionRunsOnceTheFarEndHasTheFrame() async {
        let link = Duplex()
        defer { link.stop() }
        let finished = LockedFlag()
        link.a.send(command(1)) { error in finished.set(error == nil) }
        let done = await link.waitFor { finished.value == true }
        #expect(done)
        #expect(link.atB == [command(1)])
    }

    @Test func aStoppedTransportFailsWhatWasStillWaiting() async {
        let link = Duplex()
        link.dropLane = true
        link.laneLive = true
        let outcome = LockedFlag()
        link.a.send(command(1)) { error in outcome.set(error != nil) }
        link.a.stop()
        let done = await link.waitFor { outcome.value == true }
        #expect(done)
        link.stop()
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    var value: Bool? { lock.withLock { stored } }
    func set(_ flag: Bool) { lock.withLock { stored = flag } }
}
