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

/// The pipelined pump can fail invisibly in the source (a direction stopping when the window fills, two reads outstanding, a dropped buffer) until traffic is large.
@Suite("The relay byte splice", .timeLimit(.minutes(1)))
struct RelayByteSpliceTests {
    private func spliceUnderTest(
        onStop: (@Sendable () -> Void)? = nil
    ) async throws -> (splice: RelayByteSplice, atLocal: NWConnection, atRelay: NWConnection) {
        let localEnd = try LoopbackEndpoint()
        let relayEnd = try LoopbackEndpoint()
        await localEnd.start()
        await relayEnd.start()

        let queue = DispatchQueue(label: "test.splice")
        let local = NWConnection(to: try loopback(localEnd.port), using: tcp())

        let splice = try RelayByteSplice(
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
        let arrived = await receive(sent.count, on: atRelay, within: 5)

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
        let arrived = await receive(sent.count, on: atRelay)

        #expect(arrived.count == sent.count)
        #expect(arrived == sent)
    }

    @Test func theRelayToLocalDirectionCarriesAsWell() async throws {
        // Held for the whole test: binding to `_` releases it, every `[weak self]` in the pump goes nil and nothing is copied.
        let (splice, atLocal, atRelay) = try await spliceUnderTest()
        defer { splice.cancel() }
        _ = await receive(16, on: atRelay)

        let sent = payload(bytes: 700 * 1024)
        await send(sent, on: atRelay)
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

        async let arrivingUp = receive(up.count, on: atRelay)
        async let arrivingDown = receive(down.count, on: atLocal)
        await send(up, on: atLocal)
        await send(down, on: atRelay)

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
}

