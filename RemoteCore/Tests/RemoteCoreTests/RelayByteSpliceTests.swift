import Foundation
import Network
import Testing

@testable import RemoteCore

/// A flag two threads can share, for telling a callback apart from a timeout.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

/// A listener on loopback that hands over the first connection it accepts.
///
/// Stands in for one end of a real splice: the local side is the TLS transport, the relay side is
/// `peeringd`. Both are just TCP peers as far as the splice is concerned, so a loopback listener is
/// the whole of what it needs to be exercised.
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

    /// The next accepted connection, **already started and ready to carry bytes**.
    ///
    /// Waiting for `.ready` is not tidiness: a `send` on a connection that is still setting up is
    /// accepted and then dropped, which leaves the test reading a socket nothing was ever written
    /// to. That looks exactly like a splice that stopped forwarding, which is the failure these
    /// tests exist to find.
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
        // An accepted connection is not started for you, and one that is never started never
        // becomes ready, so a `send` on it would be dropped and the test would read a socket
        // nothing was written to.
        connection.start(queue: DispatchQueue(label: "test.connection"))
        await connection.waitUntilReady()
        return connection
    }
}

extension NWConnection {
    /// Resolves once this connection can carry bytes, or once it has failed.
    ///
    /// Only safe on a connection the caller owns: it takes the state handler, so anything else
    /// waiting on that connection's state has to set its own afterwards.
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

/// Reads until `count` bytes have arrived, or until the deadline passes.
///
/// **Bounded on purpose.** A splice that has stopped forwarding never completes a `receive`, and a
/// test that waits for one hangs instead of failing — which tells you nothing about which buffer
/// went missing or how far the transfer got. This returns what it has, so the assertion that fails
/// carries the number.
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

/// Resumes a continuation at most once, whichever of the two racers gets there first.
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

/// A byte pattern that changes everywhere, so a buffer delivered twice, dropped, or reordered
/// cannot pass by being mostly the same as its neighbour.
private func payload(bytes: Int) -> Data {
    Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
}

/// What the relay path does with bytes, over real sockets.
///
/// **A test rather than a reading.** The pump was made pipelined, and the ways that can go wrong
/// are all invisible in the source: a direction that stops reading once the window fills, two
/// reads outstanding on one connection at once, or a buffer dropped at the seam. Each of those
/// looks exactly like a working splice until the traffic gets large enough to hit it.
@Suite("The relay byte splice", .timeLimit(.minutes(1)))
struct RelayByteSpliceTests {
    /// One splice, wired between two loopback endpoints.
    ///
    /// Returns the far side of each: `atLocal` is what the TLS transport would write to and read
    /// from, `atRelay` is what `peeringd` would.
    private func spliceUnderTest(
        onStop: (@Sendable () -> Void)? = nil
    ) async throws -> (splice: RelayByteSplice, atLocal: NWConnection, atRelay: NWConnection) {
        let localEnd = try LoopbackEndpoint()
        let relayEnd = try LoopbackEndpoint()
        await localEnd.start()
        await relayEnd.start()

        let queue = DispatchQueue(label: "test.splice")
        // Deliberately not started here: the splice owns this connection's lifecycle and starts
        // it itself, and it takes the state handler when it does.
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

    /// A first, small transfer: enough to prove the pumps run at all, before asking whether the
    /// window logic holds up under load. A failure here is a splice that never copied anything.
    @Test func aFewHundredBytesCrossTheSplice() async throws {
        // The splice is held for the whole test, deliberately. Binding it to `_` releases it
        // the moment the helper returns, every `[weak self]` in the pump goes nil, and the
        // splice silently copies nothing — which looks exactly like the bug these tests exist
        // to find.
        let (splice, atLocal, atRelay) = try await spliceUnderTest()
        defer { splice.cancel() }
        _ = await receive(16, on: atRelay)

        let sent = payload(bytes: 300)
        let sendError = await send(sent, on: atLocal)
        #expect(sendError == nil, "the write to the local end failed")
        let arrived = await receive(sent.count, on: atRelay, within: 5)

        #expect(arrived == sent)
    }

    /// **Larger than the window on purpose.** A transfer smaller than the splice's in-flight limit
    /// never fills it, so it never exercises the pause-and-resume that is the whole of the new
    /// logic — and it would pass against the stop-and-wait version just as well.
    @Test func aTransferLargerThanTheWindowArrivesWholeAndInOrder() async throws {
        // The splice is held for the whole test, deliberately. Binding it to `_` releases it
        // the moment the helper returns, every `[weak self]` in the pump goes nil, and the
        // splice silently copies nothing — which looks exactly like the bug these tests exist
        // to find.
        let (splice, atLocal, atRelay) = try await spliceUnderTest()
        defer { splice.cancel() }

        // The relay's routing token goes first and is not part of what is being copied.
        let token = await receive(16, on: atRelay)
        #expect(token == Data(repeating: 0x5A, count: 16), "the routing token never arrived")

        let sent = payload(bytes: 700 * 1024)
        await send(sent, on: atLocal)
        let arrived = await receive(sent.count, on: atRelay)

        #expect(arrived.count == sent.count)
        #expect(arrived == sent)
    }

    /// The other leg, which is the one that carries the picture back.
    @Test func theRelayToLocalDirectionCarriesAsWell() async throws {
        // The splice is held for the whole test, deliberately. Binding it to `_` releases it
        // the moment the helper returns, every `[weak self]` in the pump goes nil, and the
        // splice silently copies nothing — which looks exactly like the bug these tests exist
        // to find.
        let (splice, atLocal, atRelay) = try await spliceUnderTest()
        defer { splice.cancel() }
        _ = await receive(16, on: atRelay)

        let sent = payload(bytes: 700 * 1024)
        await send(sent, on: atRelay)
        let arrived = await receive(sent.count, on: atLocal)

        #expect(arrived == sent)
    }

    /// Both directions at once.
    ///
    /// This is what a session does, and it is where a splice that shares one piece of state between
    /// its two legs comes apart: the legs are independent, and a window or a read flag that is not
    /// per-direction leaves one of them waiting on the other.
    @Test func bothDirectionsCarryAtOnce() async throws {
        // The splice is held for the whole test, deliberately. Binding it to `_` releases it
        // the moment the helper returns, every `[weak self]` in the pump goes nil, and the
        // splice silently copies nothing — which looks exactly like the bug these tests exist
        // to find.
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

    /// A splice whose local end goes away has to stop rather than sit there holding the relay
    /// socket open. `onStop` is what the proxy uses to clear its reference and what the bridge
    /// uses to learn the connection is over.
    @Test func theSpliceStopsWhenTheLocalEndCloses() async throws {
        let stopped = LockedFlag()
        let (splice, atLocal, atRelay) = try await spliceUnderTest(onStop: { stopped.set() })
        _ = await receive(16, on: atRelay)

        atLocal.cancel()

        // Polled rather than awaited: the stop is delivered on the splice's own queue, and the
        // only thing worth asserting is that it arrives rather than that it arrives promptly.
        for _ in 0..<100 where !stopped.value {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(stopped.value)
        splice.cancel()
    }
}

