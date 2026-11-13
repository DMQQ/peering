import Foundation
import Network
import Testing

@testable import RemoteCore

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

/// A loopback listener standing in for one end of a real splice (TLS transport or `peeringd`).
private final class LoopbackEndpoint: @unchecked Sendable {
    let listener: NWListener
    private let lock = NSLock()
    private var accepted: NWConnection?
    private var waiter: CheckedContinuation<NWConnection, Never>?

    init() throws {
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: options)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            self.lock.lock()
            if let waiter = self.waiter {
                self.waiter = nil
                self.lock.unlock()
                waiter.resume(returning: connection)
            } else {
                self.accepted = connection
                self.lock.unlock()
            }
        }
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    func start() async {
        await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state { continuation.resume() }
            }
            listener.start(queue: DispatchQueue(label: "test.loopback.listener"))
        }
    }

    /// Waiting for `.ready` matters: a `send` on a connection still setting up is dropped, which looks exactly like a splice that stopped forwarding.
    func next() async -> NWConnection {
        let connection = await withCheckedContinuation { continuation in
            lock.lock()
            if let accepted {
                self.accepted = nil
                lock.unlock()
                continuation.resume(returning: accepted)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
        // An accepted connection is not started for you, and an unstarted one never becomes ready.
        connection.start(queue: DispatchQueue(label: "test.connection"))
        await connection.waitUntilReady()
        return connection
    }
}

extension NWConnection {
    /// Takes the state handler, so anything else waiting on this connection's state must set its own afterwards.
    func waitUntilReady() async {
        await withCheckedContinuation { continuation in
            let resumed = LockedFlag()
            stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    if !resumed.value {
                        resumed.set()
                        continuation.resume()
                    }
                default:
                    break
                }
            }
        }
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ new: Value) { lock.withLock { value = new } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&value) } }
}

private func tcp() -> NWParameters {
    let options = NWProtocolTCP.Options()
    options.noDelay = true
    return NWParameters(tls: nil, tcp: options)
}

private func loopback(_ port: UInt16) throws -> NWEndpoint {
    guard let port = NWEndpoint.Port(rawValue: port) else {
        throw RelayTunnelError.invalidPort(port)
    }
    return .hostPort(host: "127.0.0.1", port: port)
}

@discardableResult
private func send(_ data: Data, on connection: NWConnection) async -> (any Error)? {
    await withCheckedContinuation { continuation in
        connection.send(content: data, completion: .contentProcessed { error in
            continuation.resume(returning: error)
        })
    }
}

/// Bounded on purpose: a stalled splice never completes a `receive`, so the test returns what it has and the assertion carries the number.
private func receive(
    _ count: Int, on connection: NWConnection, within seconds: Double = 15
) async -> Data {
    let deadline = Date().addingTimeInterval(seconds)
    var collected = Data()
    while collected.count < count, Date() < deadline {
        let (chunk, isComplete, error) = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
                data, _, isComplete, error in
                once.finish((data ?? Data(), isComplete, error))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                once.finish((Data(), false, nil))
            }
        }
        collected.append(chunk)
        if isComplete || error != nil { break }
    }
    return collected
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, Bool, (any Error)?), Never>?
    private var finished = false

    init(_ continuation: CheckedContinuation<(Data, Bool, (any Error)?), Never>) {
        self.continuation = continuation
    }

    func finish(_ value: (Data, Bool, (any Error)?)) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

private func payload(bytes: Int) -> Data {
    Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
}


/// The relay's end of the splice as the far peer sees it: reads the pipe's frames and acknowledges them, and writes the stream as frames.
private final class FarEnd: @unchecked Sendable {
    let connection: NWConnection
    private var decoder = ControlPipeLengthDecoder()
    private var receiver = ControlPipeReceiver()
    private var written: UInt64 = 0

    init(_ connection: NWConnection) { self.connection = connection }

    func read(_ count: Int, within seconds: Double = 15) async -> Data {
        let deadline = Date().addingTimeInterval(seconds)
        var collected = Data()
        while collected.count < count, Date() < deadline {
            let chunk = await receive(1, on: connection, within: 2)
            guard let frames = try? decoder.feed(chunk) else { break }
            for case .data(let offset, let payload) in frames {
                collected.append(receiver.receive(offset: offset, payload: payload))
            }
            if !frames.isEmpty {
                await send(ControlPipeLengthDecoder.wrap(.ack(upTo: receiver.ackPoint)), on: connection)
            }
        }
        return collected
    }

    func write(_ bytes: Data) async {
        var start = 0
        while start < bytes.count {
            let end = min(bytes.count, start + 16 * 1024)
            let frame = ControlPipeFrame.data(offset: written, payload: bytes.subdata(in: start..<end))
            written += UInt64(end - start)
            await send(ControlPipeLengthDecoder.wrap(frame), on: connection)
            start = end
        }
    }
}

/// The pipelined pump can fail invisibly in the source (a direction stopping when the window fills, two reads outstanding, a dropped buffer) until traffic is large.
@Suite("The control pipe splice", .timeLimit(.minutes(1)))
struct ControlPipeSpliceTests {
    private func spliceUnderTest(
        onStop: (@Sendable () -> Void)? = nil
    ) async throws -> (splice: ControlPipeSplice, atLocal: NWConnection, atRelay: NWConnection) {
        let localEnd = try LoopbackEndpoint()
        let relayEnd = try LoopbackEndpoint()
        await localEnd.start()
        await relayEnd.start()

        let queue = DispatchQueue(label: "test.splice")
        let local = NWConnection(to: try loopback(localEnd.port), using: tcp())

        let splice = try ControlPipeSplice(
            local: local,
            relayHost: "127.0.0.1",
            relayPort: relayEnd.port,
            token: Data(repeating: 0x5A, count: 16),
            queue: queue,
            onStop: onStop
        )
        splice.start()

        return (splice, await localEnd.next(), await relayEnd.next())
    }

    @Test func aFewHundredBytesCrossTheSplice() async throws {
        // Held for the whole test: binding to `_` releases it, every `[weak self]` in the pump goes nil and nothing is copied.
        let (splice, atLocal, atRelay) = try await spliceUnderTest()
        defer { splice.cancel() }
        _ = await receive(16, on: atRelay)

        let sent = payload(bytes: 300)
        let sendError = await send(sent, on: atLocal)
        #expect(sendError == nil, "the write to the local end failed")
        let arrived = await FarEnd(atRelay).read(sent.count, within: 5)

        #expect(arrived == sent)
    }

    /// Larger than the window on purpose: a smaller transfer never exercises pause-and-resume.
    @Test func aTransferLargerThanTheWindowArrivesWholeAndInOrder() async throws {
        // Held for the whole test: binding to `_` releases it, every `[weak self]` in the pump goes nil and nothing is copied.
        let (splice, atLocal, atRelay) = try await spliceUnderTest()
        defer { splice.cancel() }

        let token = await receive(16, on: atRelay)
        #expect(token == Data(repeating: 0x5A, count: 16), "the routing token never arrived")

        let sent = payload(bytes: 700 * 1024)
        await send(sent, on: atLocal)
        let arrived = await FarEnd(atRelay).read(sent.count)

        #expect(arrived.count == sent.count)
        #expect(arrived == sent)
    }

    @Test func theRelayToLocalDirectionCarriesAsWell() async throws {
        // Held for the whole test: binding to `_` releases it, every `[weak self]` in the pump goes nil and nothing is copied.
        let (splice, atLocal, atRelay) = try await spliceUnderTest()
        defer { splice.cancel() }
        _ = await receive(16, on: atRelay)

        let sent = payload(bytes: 700 * 1024)
        await FarEnd(atRelay).write(sent)
        let arrived = await receive(sent.count, on: atLocal)

        #expect(arrived == sent)
    }

    /// The legs are independent: state shared between them leaves one waiting on the other.
    @Test func bothDirectionsCarryAtOnce() async throws {
        // Held for the whole test: binding to `_` releases it, every `[weak self]` in the pump goes nil and nothing is copied.
        let (splice, atLocal, atRelay) = try await spliceUnderTest()
        defer { splice.cancel() }
        _ = await receive(16, on: atRelay)

        let up = payload(bytes: 500 * 1024)
        let down = Data(payload(bytes: 500 * 1024)
            .enumerated().map { $0.element &+ UInt8($0.offset % 251) })

        let far = FarEnd(atRelay)
        async let arrivingUp = far.read(up.count)
        async let arrivingDown = receive(down.count, on: atLocal)
        await send(up, on: atLocal)
        await far.write(down)

        let upArrived = await arrivingUp
        let downArrived = await arrivingDown
        #expect(upArrived == up)
        #expect(downArrived == down)
    }

    @Test func theSpliceStopsWhenTheLocalEndCloses() async throws {
        let stopped = LockedFlag()
        let (splice, atLocal, atRelay) = try await spliceUnderTest(onStop: { stopped.set() })
        _ = await receive(16, on: atRelay)

        atLocal.cancel()

        for _ in 0..<100 where !stopped.value {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(stopped.value)
        splice.cancel()
    }

    @Test func aLiveDirectPathCarriesTheStreamAndALostOneHandsItBackToTheRelay() async throws {
        let (splice, atLocal, atRelay) = try await spliceUnderTest()
        defer { splice.cancel() }
        _ = await receive(16, on: atRelay)

        let live = LockedValue(true)
        let onLane = LockedValue([Data]())
        splice.attachDirect(send: { frame in onLane.update { $0.append(frame) } }, isLive: { live.get() })

        let sent = payload(bytes: 3000)
        await send(sent, on: atLocal)
        for _ in 0..<100 where onLane.get().isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let carried = onLane.get().compactMap(ControlPipeFrame.decode).reduce(0) { total, frame in
            if case .data(_, let payload) = frame { return total + payload.count }
            return total
        }
        #expect(carried >= sent.count, "the direct path was live and did not carry the stream")

        live.set(false)
        let arrived = await FarEnd(atRelay).read(sent.count, within: 5)
        #expect(arrived == sent, "the bytes the direct path never acknowledged did not reach the relay")
    }

    @Test func aFrameFromTheDirectPathReachesTheLocalEndAndIsAcknowledgedBackThere() async throws {
        let (splice, atLocal, atRelay) = try await spliceUnderTest()
        defer { splice.cancel() }
        _ = await receive(16, on: atRelay)

        let onLane = LockedValue([Data]())
        splice.attachDirect(send: { frame in onLane.update { $0.append(frame) } }, isLive: { false })

        let sent = payload(bytes: 500)
        splice.receiveDirect(ControlPipeFrame.data(offset: 0, payload: sent).encoded())
        #expect(await receive(sent.count, on: atLocal, within: 5) == sent)
        for _ in 0..<100 where onLane.get().isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(onLane.get().compactMap(ControlPipeFrame.decode).contains(.ack(upTo: 500)))
    }
}
