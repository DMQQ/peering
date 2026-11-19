import Foundation
import os

private let quicLog = Logger(subsystem: "pl.dmq.peering", category: "quic")

/// The QUIC spike's measurement, run by the phone against a Mac's ``QuicEchoServer``: handshake time, round trips on a stream, and datagram throughput. Diagnostic only, not part of a session.
public enum QuicProbe {
    static let pingStream: UInt64 = 0
    static let reportStream: UInt64 = 4
    static let datagramSize = 1200

    public struct Report: Sendable {
        public var lines: [String] = []
    }

    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var streams: [UInt64: Data] = [:]

        func add(_ bytes: Data, stream: UInt64) {
            lock.withLock { streams[stream, default: Data()].append(bytes) }
        }

        func take(stream: UInt64, count: Int) -> Data? {
            lock.withLock {
                guard let held = streams[stream], held.count >= count else { return nil }
                streams[stream] = held.dropFirst(count)
                return Data(held.prefix(count))
            }
        }

        func takeLine(stream: UInt64) -> String? {
            lock.withLock {
                guard let held = streams[stream], let end = held.firstIndex(of: 0x0A) else { return nil }
                streams[stream] = held[held.index(after: end)...]
                return String(decoding: held[..<end], as: UTF8.self)
            }
        }
    }

    public static func run(host: String, port: UInt16, identity: SelfSignedIdentity, relayToken: Data? = nil) async -> Report {
        var report = Report()
        func say(_ line: String) {
            report.lines.append(line)
            quicLog.notice("probe: \(line, privacy: .public)")
        }
        guard let peer = QuicAddress(host: host, port: port) else {
            say("\(host) is not a numeric address")
            return report
        }
        do {
            let configuration = try QuicConfiguration(identity: identity)
            let inbox = Inbox()
            let relay = relayToken.map { QuicEndpoint.RelayRoute(address: peer, token: $0) }
            let endpoint = try QuicEndpoint.connect(to: peer, configuration: configuration, queue: DispatchQueue(label: "pl.dmq.peering.quic.probe"), relay: relay)
            endpoint.onActivity = { connection in
                for read in connection.readStreams() { inbox.add(read.bytes, stream: read.stream) }
            }
            defer { endpoint.cancel() }

            let started = ContinuousClock.now
            guard let connection = await waitFor(seconds: 5, { endpoint.currentConnection.flatMap { $0.isEstablished ? $0 : nil } }) else {
                say("no handshake within 5 s from \(peer.description)")
                return report
            }
            say("handshake \(milliseconds(ContinuousClock.now - started)) ms to \(peer.description)")
            say("the Mac's certificate: \(connection.peerCertificate.map { "\($0.count) bytes" } ?? "missing")")

            var trips: [Double] = []
            for sequence in 0..<20 {
                let ping = Data(String(format: "%08d", sequence).utf8)
                let sent = ContinuousClock.now
                connection.send(ping, onStream: pingStream)
                endpoint.queue.async { endpoint.flush() }
                guard await waitFor(seconds: 2, { inbox.take(stream: pingStream, count: ping.count) }) != nil else {
                    say("ping \(sequence) unanswered")
                    continue
                }
                trips.append(milliseconds(ContinuousClock.now - sent))
            }
            let sorted = trips.sorted()
            if !sorted.isEmpty {
                say("stream round trip: median \(format(sorted[sorted.count / 2])) ms, best \(format(sorted[0])) ms, worst \(format(sorted[sorted.count - 1])) ms")
            }

            let payload = Data(repeating: 0x5A, count: datagramSize)
            let burstStarted = ContinuousClock.now
            var queued = 0
            while ContinuousClock.now - burstStarted < .seconds(3) {
                if connection.sendDatagram(payload) {
                    queued += 1
                } else {
                    endpoint.queue.async { endpoint.flush() }
                    try? await Task.sleep(for: .milliseconds(1))
                }
                if queued % 32 == 0 { endpoint.queue.async { endpoint.flush() } }
            }
            endpoint.queue.async { endpoint.flush() }
            try? await Task.sleep(for: .milliseconds(500))
            connection.send(Data("report\n".utf8), onStream: reportStream)
            endpoint.queue.async { endpoint.flush() }
            if let line = await waitFor(seconds: 3, { inbox.takeLine(stream: reportStream) }), let received = Int(line) {
                let megabits = Double(received * datagramSize * 8) / 3 / 1_000_000
                say("datagrams: \(queued) queued, \(received) arrived (\(format(Double(received) / Double(max(queued, 1)) * 100)) %), \(format(megabits)) Mbit/s")
            } else {
                say("datagrams: \(queued) queued, the Mac did not report a count")
            }
            if let roundTrip = connection.roundTrip { say("QUIC's own smoothed round trip: \(format(milliseconds(roundTrip))) ms") }
            connection.close(reason: "probe done")
            endpoint.queue.async { endpoint.flush() }
        } catch {
            say("failed: \(error)")
        }
        return report
    }

    private static func waitFor<Value>(seconds: Double, _ check: () -> Value?) async -> Value? {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if let value = check() { return value }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return check()
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }

    private static func format(_ value: Double) -> String { String(format: "%.1f", value) }
}

/// The Mac's side of ``QuicProbe``: echoes the ping stream, counts datagrams, and reports the count when asked.
public final class QuicEchoServer: @unchecked Sendable {
    public static let port: UInt16 = 51_517
    private let endpoint: QuicEndpoint
    /// Touched only on the endpoint's queue.
    private var datagramsReceived = 0

    public var listeningPort: UInt16 { endpoint.localPort }

    public init(identity: SelfSignedIdentity, port: UInt16 = QuicEchoServer.port, relay: QuicEndpoint.RelayRoute? = nil) throws {
        let configuration = try QuicConfiguration(identity: identity)
        endpoint = try QuicEndpoint.listen(port: port, configuration: configuration, queue: DispatchQueue(label: "pl.dmq.peering.quic.echo"), relay: relay)
        endpoint.onActivity = { [weak self] connection in self?.serve(connection) }
        quicLog.notice("QUIC echo server listening on UDP \(port, privacy: .public)")
    }

    private func serve(_ connection: QuicConnection) {
        datagramsReceived += connection.readDatagrams().count
        for read in connection.readStreams() {
            switch read.stream {
            case QuicProbe.pingStream:
                connection.send(read.bytes, onStream: read.stream)
            case QuicProbe.reportStream:
                connection.send(Data("\(datagramsReceived)\n".utf8), onStream: read.stream)
                datagramsReceived = 0
            default:
                break
            }
        }
    }

    public func stop() { endpoint.cancel() }
}
