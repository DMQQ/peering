import Darwin
import Foundation
import os

private let quicLog = Logger(subsystem: "pl.dmq.peering", category: "quic")

/// A UDP socket that drives one QUIC connection: it reads packets into it, writes what it produces, and runs its timer.
///
/// The phone dials with ``connect(to:configuration:queue:)``; the Mac waits with ``listen(port:configuration:queue:)`` and serves the first peer that arrives. `@unchecked Sendable`: all mutable state is touched only on `queue`.
public final class QuicEndpoint: @unchecked Sendable {
    public let queue: DispatchQueue
    private let fd: Int32
    private let configuration: QuicConfiguration
    private let local: QuicAddress
    private var source: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var connection: QuicConnection?
    private var closed = false
    private var relay: RelayRoute?

    /// The relay's UDP port and this end's token: the relay forwards a datagram by the token in front of it and strips it, so the token goes on every packet sent there and never arrives on one.
    public struct RelayRoute: Sendable {
        public let address: QuicAddress
        public let token: Data

        public init(address: QuicAddress, token: Data) {
            self.address = address
            self.token = token
        }
    }

    /// Called on `queue` after every batch of packets or a timeout, so the owner can read streams and datagrams and queue replies.
    public var onActivity: (@Sendable (QuicConnection) -> Void)?

    /// Called on `queue` after packets have been written.
    public var onFlushed: (@Sendable () -> Void)?

    /// Called once on `queue` when the connection has closed, by either end or by its idle timeout.
    public var onClosed: (@Sendable (QuicConnection) -> Void)?
    private var reportedClosed = false
    private var lastHeard: ContinuousClock.Instant?
    /// The last address other than the relay a packet came from, logged once per change: the sign a direct path's packets get through.
    private var lastStranger: QuicAddress?
    private lazy var pacer = QuicPacer(queue: queue) { [unowned self] packet in send(packet) }

    public enum Failure: Error {
        case socket(Int32)
    }

    private init(fd: Int32, local: QuicAddress, configuration: QuicConfiguration, queue: DispatchQueue, relay: RelayRoute?) {
        self.fd = fd
        self.local = local
        self.configuration = configuration
        self.queue = queue
        self.relay = relay
    }

    /// Dials `peer`, which is the relay's address when `relay` is given.
    public static func connect(to peer: QuicAddress, configuration: QuicConfiguration, queue: DispatchQueue, relay: RelayRoute? = nil) throws -> QuicEndpoint {
        let (fd, local) = try openSocket(port: 0)
        let endpoint = QuicEndpoint(fd: fd, local: local, configuration: configuration, queue: queue, relay: relay)
        let connection = try QuicConnection.connect(local: local, peer: peer, configuration: configuration)
        queue.async {
            endpoint.connection = connection
            endpoint.startReading()
            endpoint.bindRelay()
            endpoint.flush()
        }
        return endpoint
    }

    /// Waits for a peer on `port`, or behind the relay when `relay` is given.
    public static func listen(port: UInt16, configuration: QuicConfiguration, queue: DispatchQueue, relay: RelayRoute? = nil) throws -> QuicEndpoint {
        let (fd, local) = try openSocket(port: port)
        let endpoint = QuicEndpoint(fd: fd, local: local, configuration: configuration, queue: queue, relay: relay)
        queue.async {
            endpoint.startReading()
            endpoint.bindRelay()
        }
        return endpoint
    }

    /// The token alone tells the relay where this end is, so the peer's first packet has somewhere to go.
    private func bindRelay() {
        guard let relay else { return }
        write(relay.token, to: relay.address)
    }

    private func send(_ packet: QuicConnection.Packet) {
        guard !closed else { return }
        if let relay, packet.destination == relay.address {
            write(relay.token + packet.bytes, to: packet.destination)
        } else {
            write(packet.bytes, to: packet.destination)
        }
    }

    private func write(_ bytes: Data, to destination: QuicAddress) {
        bytes.withUnsafeBytes { buffer in
            destination.withSockaddr { pointer, length in
                _ = sendto(fd, buffer.baseAddress, buffer.count, 0, pointer, length)
            }
        }
    }

    public var localPort: UInt16 { local.port }
    var localAddress: QuicAddress { local }

    /// Time since the last packet arrived, from anywhere. Call on `queue`.
    var silence: Duration? { lastHeard.map { .now - $0 } }

    /// One byte to `address`: no QUIC stack reads it, but it opens this end's NAT to that address, so the peer's packets are let in. Call on `queue`.
    func knock(_ address: QuicAddress) {
        guard !closed else { return }
        write(Data([0]), to: address)
    }

    /// Repeats the bare-token bind, so the relay keeps this end's route while the session runs elsewhere and has it to fall back to. Call on `queue`.
    func refreshRelayBinding() {
        guard !closed else { return }
        bindRelay()
    }

    var relayAddress: QuicAddress? { relay?.address }

    /// Adopts a relay route mid-session and binds it at once.
    func useRelay(_ route: RelayRoute) {
        queue.async { [self] in
            relay = route
            bindRelay()
        }
    }

    /// The connection once there is one. Not for use on `queue`.
    public var currentConnection: QuicConnection? { queue.sync { connection } }

    /// Sends what the connection has queued. Call on `queue` after writing to it.
    public func flush() {
        guard let connection, !closed else { return }
        pacer.submit(connection.outgoing())
        onFlushed?()
        rearmTimer()
    }

    public func cancel() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            timer?.cancel()
            source?.cancel()
        }
    }

    // MARK: - On `queue`

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAll() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    private func readAll() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var received = false
        while true {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let read = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, MSG_DONTWAIT, $0, &length) }
            }
            guard read > 0 else { break }
            let from = QuicAddress(storage: storage, length: length)
            lastHeard = .now
            if connection == nil {
                do {
                    connection = try QuicConnection.accept(local: local, peer: from, configuration: configuration)
                    quicLog.notice("a peer arrived from \(from.description, privacy: .public)")
                } catch {
                    continue
                }
            }
            if from != relay?.address, from != lastStranger, connection?.isEstablished == true {
                lastStranger = from
                quicLog.notice("a packet from \(from.description, privacy: .public), not the relay")
            }
            connection?.receive(Data(buffer[0..<read]), from: from, to: local)
            received = true
        }
        guard received, let connection else { return }
        onActivity?(connection)
        flush()
        reportIfClosed()
    }

    private func reportIfClosed() {
        guard let connection, connection.isClosed, !reportedClosed else { return }
        reportedClosed = true
        onClosed?(connection)
    }

    private func rearmTimer() {
        timer?.cancel()
        timer = nil
        guard let connection, let timeout = connection.timeout else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let (seconds, attoseconds) = timeout.components
        let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
        timer.schedule(deadline: .now() + .nanoseconds(max(0, nanoseconds)))
        timer.setEventHandler { [weak self] in
            guard let self, let connection = self.connection else { return }
            connection.onTimeout()
            self.onActivity?(connection)
            self.flush()
            self.reportIfClosed()
        }
        self.timer = timer
        timer.resume()
    }

    static func openSocket(port: UInt16) throws -> (Int32, QuicAddress) {
        let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw Failure.socket(errno) }
        var no: Int32 = 0
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw Failure.socket(code)
        }
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, QuicAddress(storage: storage, length: length))
    }
}
