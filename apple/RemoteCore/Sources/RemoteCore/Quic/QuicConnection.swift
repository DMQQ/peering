import Foundation
import PeeringQuicFFI
import Security

/// One QUIC connection, without I/O: packets go in through ``receive(_:from:to:)`` and come out of ``outgoing()``; whoever owns the socket moves them.
///
/// `@unchecked Sendable`: every call into quiche happens under `lock`, including in the extensions that see it.
public final class QuicConnection: @unchecked Sendable {
    let lock = NSLock()
    let connection: OpaquePointer
    /// Kept alive for as long as the connection, which reads it.
    private let configuration: QuicConfiguration

    public struct Packet: Sendable {
        public let bytes: Data
        public let destination: QuicAddress
        /// How long quiche wants it held before writing, to spread a burst over the round trip.
        public let delay: Duration
    }

    public enum Failure: Error {
        case couldNotCreate
        case quiche(Int)
    }

    /// Every connection id this end has given the peer, the first one included; a packet's destination id is one of these.
    public var sourceIDs: [Data] { lock.withLock { _sourceIDs } }
    var _sourceIDs: [Data]

    private init(connection: OpaquePointer, configuration: QuicConfiguration, sourceID: Data) {
        self.connection = connection
        self.configuration = configuration
        _sourceIDs = [sourceID]
    }

    /// The phone's end.
    public static func connect(local: QuicAddress, peer: QuicAddress, configuration: QuicConfiguration) throws -> QuicConnection {
        let scid = Self.randomConnectionID()
        let made = scid.withUnsafeBytes { id in
            local.withSockaddr { localPointer, localLength in
                peer.withSockaddr { peerPointer, peerLength in
                    quiche_connect(nil, id.bindMemory(to: UInt8.self).baseAddress, id.count, localPointer, localLength, peerPointer, peerLength, configuration.pointer)
                }
            }
        }
        guard let made else { throw Failure.couldNotCreate }
        return QuicConnection(connection: made, configuration: configuration, sourceID: scid)
    }

    /// The Mac's end, for a first packet from a peer it does not know yet.
    public static func accept(local: QuicAddress, peer: QuicAddress, configuration: QuicConfiguration) throws -> QuicConnection {
        let scid = Self.randomConnectionID()
        let made = scid.withUnsafeBytes { id in
            local.withSockaddr { localPointer, localLength in
                peer.withSockaddr { peerPointer, peerLength in
                    quiche_accept(id.bindMemory(to: UInt8.self).baseAddress, id.count, nil, 0, localPointer, localLength, peerPointer, peerLength, configuration.pointer)
                }
            }
        }
        guard let made else { throw Failure.couldNotCreate }
        return QuicConnection(connection: made, configuration: configuration, sourceID: scid)
    }

    deinit {
        quiche_conn_free(connection)
    }

    /// The destination connection id of a received packet, and whether it opens a connection (an Initial), read without decrypting.
    public static func header(of packet: Data) -> (destinationID: Data, isInitial: Bool)? {
        var bytes = [UInt8](packet)
        var version: UInt32 = 0
        var type: UInt8 = 0
        var scid = [UInt8](repeating: 0, count: 20), scidLength = 20
        var dcid = [UInt8](repeating: 0, count: 20), dcidLength = 20
        var token = [UInt8](repeating: 0, count: 256), tokenLength = 256
        let parsed = quiche_header_info(&bytes, bytes.count, 16, &version, &type, &scid, &scidLength, &dcid, &dcidLength, &token, &tokenLength)
        guard parsed >= 0 else { return nil }
        // quiche numbers an Initial packet 1.
        return (Data(dcid[0..<dcidLength]), type == 1)
    }

    static func randomConnectionID() -> Data {
        var bytes = Data(count: 16)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        // A failed random source would give every connection the same id; there is no safe fallback.
        precondition(status == errSecSuccess, "the system random source failed")
        return bytes
    }

    // MARK: - Packets

    /// Hands one received packet to quiche. A packet it refuses (not this connection's, damaged) is dropped: that is what a lossy path looks like too.
    public func receive(_ packet: Data, from: QuicAddress, to: QuicAddress) {
        var bytes = [UInt8](packet)
        lock.withLock {
            var from = from
            var to = to
            withUnsafeMutablePointer(to: &from.storage) { fromStorage in
                withUnsafeMutablePointer(to: &to.storage) { toStorage in
                    fromStorage.withMemoryRebound(to: sockaddr.self, capacity: 1) { fromPointer in
                        toStorage.withMemoryRebound(to: sockaddr.self, capacity: 1) { toPointer in
                            var info = quiche_recv_info(from: fromPointer, from_len: from.length, to: toPointer, to_len: to.length)
                            _ = quiche_conn_recv(connection, &bytes, bytes.count, &info)
                        }
                    }
                }
            }
        }
    }

    /// Every packet quiche wants sent now.
    public func outgoing() -> [Packet] {
        lock.withLock {
            var packets: [Packet] = []
            var buffer = [UInt8](repeating: 0, count: 1500)
            while true {
                var destination = sockaddr_storage()
                var destinationLength = socklen_t(0)
                var delayNanos: UInt64 = 0
                let written = peering_quic_conn_send(connection, &buffer, buffer.count, &destination, &destinationLength, &delayNanos)
                guard written > 0 else { break }
                packets.append(Packet(
                    bytes: Data(buffer[0..<written]),
                    destination: QuicAddress(storage: destination, length: destinationLength),
                    delay: .nanoseconds(Int64(min(delayNanos, UInt64(Int64.max))))
                ))
            }
            return packets
        }
    }

    /// When quiche next needs ``onTimeout()``, or nil when it needs nothing.
    public var timeout: Duration? {
        let milliseconds = lock.withLock { quiche_conn_timeout_as_millis(connection) }
        return milliseconds == UInt64.max ? nil : .milliseconds(Int64(milliseconds))
    }

    public func onTimeout() {
        lock.withLock { quiche_conn_on_timeout(connection) }
    }

    // MARK: - State

    public var isEstablished: Bool { lock.withLock { quiche_conn_is_established(connection) } }
    public var isClosed: Bool { lock.withLock { quiche_conn_is_closed(connection) } }
    public var isServer: Bool { lock.withLock { quiche_conn_is_server(connection) } }

    /// The peer's certificate, DER, once the handshake has got that far. The caller checks it against the pin.
    public var peerCertificate: Data? {
        lock.withLock {
            var pointer: UnsafePointer<UInt8>?
            var length = 0
            quiche_conn_peer_cert(connection, &pointer, &length)
            guard let pointer, length > 0 else { return nil }
            return Data(bytes: pointer, count: length)
        }
    }

    /// The smoothed round trip of the active path.
    public var roundTrip: Duration? { pathSample?.roundTrip }

    /// Why a closed connection closed, in words for the log: which end ended it and with what, or the idle timeout, which means the path stopped carrying packets.
    public var closeReason: String {
        lock.withLock {
            if quiche_conn_is_timed_out(connection) { return "idle timeout: nothing arrived for the idle period" }
            var isApp = false
            var code: UInt64 = 0
            var reason: UnsafePointer<UInt8>?
            var length = 0
            let text = { reason.map { String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self) } ?? "" }
            if quiche_conn_peer_error(connection, &isApp, &code, &reason, &length) {
                return "the peer closed it (\(isApp ? "application" : "transport") code \(code)) \(text())"
            }
            if quiche_conn_local_error(connection, &isApp, &code, &reason, &length) {
                return "this end closed it (\(isApp ? "application" : "transport") code \(code)) \(text())"
            }
            return "no reason recorded"
        }
    }

    public func close(reason: String) {
        lock.withLock {
            let bytes = Array(reason.utf8)
            _ = quiche_conn_close(connection, true, 0, bytes, bytes.count)
        }
    }

    // MARK: - Streams

    /// Queues bytes on a stream; returns how many quiche took (flow control may take fewer).
    @discardableResult
    public func send(_ bytes: Data, onStream stream: UInt64, finished: Bool = false) -> Int {
        lock.withLock {
            var errorCode: UInt64 = 0
            let written = bytes.withUnsafeBytes {
                quiche_conn_stream_send(connection, stream, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, finished, &errorCode)
            }
            return max(0, written)
        }
    }

    /// False until the stream exists, which is after its first write.
    @discardableResult
    public func setPriority(ofStream stream: UInt64, urgency: UInt8, incremental: Bool) -> Bool {
        lock.withLock { quiche_conn_stream_priority(connection, stream, urgency, incremental) == 0 }
    }

    /// Everything readable now, by stream.
    public func readStreams() -> [(stream: UInt64, bytes: Data, finished: Bool)] {
        lock.withLock {
            var results: [(UInt64, Data, Bool)] = []
            guard let iterator = quiche_conn_readable(connection) else { return [] }
            defer { quiche_stream_iter_free(iterator) }
            var stream: UInt64 = 0
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while quiche_stream_iter_next(iterator, &stream) {
                var collected = Data()
                var finished = false
                while true {
                    var fin = false
                    var errorCode: UInt64 = 0
                    let read = quiche_conn_stream_recv(connection, stream, &buffer, buffer.count, &fin, &errorCode)
                    guard read > 0 else { break }
                    collected.append(contentsOf: buffer[0..<read])
                    finished = finished || fin
                }
                results.append((stream, collected, finished))
            }
            return results
        }
    }

    // MARK: - Datagrams

    /// Queues one unreliable datagram. False when it does not fit or the queue is full; it is never retried.
    @discardableResult
    public func sendDatagram(_ bytes: Data) -> Bool {
        lock.withLock {
            bytes.withUnsafeBytes { quiche_conn_dgram_send(connection, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) } >= 0
        }
    }

    public func readDatagrams() -> [Data] {
        lock.withLock {
            var datagrams: [Data] = []
            var buffer = [UInt8](repeating: 0, count: 1500)
            while true {
                let read = quiche_conn_dgram_recv(connection, &buffer, buffer.count)
                guard read > 0 else { break }
                datagrams.append(Data(buffer[0..<read]))
            }
            return datagrams
        }
    }
}
