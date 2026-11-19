import Darwin
import Foundation
import os

private let listenerLog = Logger(subsystem: "pl.dmq.peering", category: "quic")

/// One UDP port serving any number of QUIC connections, each handed out as a ``QuicFrameLink``: the Mac's end of every session. A packet goes to the connection whose ids include its destination id; an Initial for an unknown id opens a new one.
///
/// Relay allocations are attached as extra sockets (``attachRelay(_:)``) feeding the same table, so a phone whose session began on the LAN can move it through the relay and arrive on the connection it already has. Replies to an address go out through the socket that address was last heard on.
///
/// `@unchecked Sendable`: all mutable state is touched only on `queue`.
public final class QuicListener: @unchecked Sendable {
    public let queue: DispatchQueue
    private let fd: Int32
    private let local: QuicAddress
    private let configuration: QuicConfiguration
    private var source: DispatchSourceRead?
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var byID: [Data: ObjectIdentifier] = [:]
    private var ports: [Int32: RelayPort] = [:]
    private var housekeeping: DispatchSourceTimer?
    private var closed = false

    /// A relay port nobody arrived on within this is given up.
    static let relayArrivalWindow: Duration = .seconds(30)
    /// The relay forgets a route it has not heard from; a port in use repeats its bind this often.
    static let relayRefreshInterval: Duration = .seconds(10)
    /// A port its connection has stopped using (it moved back to the LAN) is closed after this. The relay forgets it sooner, and a phone that needs the relay again asks for a new allocation.
    static let relayDisuseLimit: Duration = .seconds(120)

    private final class Entry {
        let connection: QuicConnection
        let link: QuicFrameLink
        var timer: DispatchSourceTimer?
        var knownIDs = 0
        var pacer: QuicPacer?
        /// The relay port each peer address was last heard through; an address absent here is answered from the listener's own socket.
        var replyVia: [QuicAddress: Int32] = [:]
        var lastHeard: ContinuousClock.Instant?

        init(connection: QuicConnection, link: QuicFrameLink) {
            self.connection = connection
            self.link = link
        }
    }

    private final class RelayPort {
        let fd: Int32
        let route: QuicEndpoint.RelayRoute
        let opened = ContinuousClock.now
        var source: DispatchSourceRead?
        var owner: ObjectIdentifier?
        var lastHeard: ContinuousClock.Instant?
        var lastBound = ContinuousClock.now

        init(fd: Int32, route: QuicEndpoint.RelayRoute) {
            self.fd = fd
            self.route = route
        }
    }

    /// A new connection's link, before its handshake finishes, with the relay route it came through (nil on the LAN); called on `queue`.
    public var onLink: (@Sendable (QuicFrameLink, QuicEndpoint.RelayRoute?) -> Void)?

    /// A connection that already existed arrived through a newly attached relay port: a session carried from the LAN onto the relay. Called on `queue`.
    public var onRelayAdopted: (@Sendable (QuicFrameLink, QuicEndpoint.RelayRoute) -> Void)?

    public enum Failure: Error {
        case socket(Int32)
    }

    public init(port: UInt16, configuration: QuicConfiguration, label: String) throws {
        let (fd, local) = try QuicEndpoint.openSocket(port: port)
        self.fd = fd
        self.local = local
        self.configuration = configuration
        queue = DispatchQueue(label: label)
        queue.async { [self] in
            source = startReading(fd, port: nil)
            startHousekeeping()
        }
    }

    public var localPort: UInt16 { local.port }

    /// Waits behind the relay as well: a socket of its own, bound to the relay with `route`'s token, whose packets join the same connections.
    public func attachRelay(_ route: QuicEndpoint.RelayRoute) throws {
        let (portFD, _) = try QuicEndpoint.openSocket(port: 0)
        queue.async { [self] in
            guard !closed else {
                Darwin.close(portFD)
                return
            }
            let port = RelayPort(fd: portFD, route: route)
            ports[portFD] = port
            port.source = startReading(portFD, port: port)
            bind(port)
        }
    }

    public func cancel() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            for entry in entries.values {
                entry.timer?.cancel()
                entry.connection.close(reason: "listener stopped")
                flush(entry)
            }
            entries = [:]
            byID = [:]
            housekeeping?.cancel()
            for port in ports.values { port.source?.cancel() }
            ports = [:]
            source?.cancel()
        }
    }

    // MARK: - On `queue`

    private func startReading(_ descriptor: Int32, port: RelayPort?) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self, weak port] in
            guard let self else { return }
            if let port { readAll(port.fd, port: port) } else { readAll(fd, port: nil) }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        return source
    }

    private func readAll(_ descriptor: Int32, port: RelayPort?) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var touched: Set<ObjectIdentifier> = []
        while true {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let read = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, &buffer, buffer.count, MSG_DONTWAIT, $0, &length) }
            }
            guard read > 0 else { break }
            let packet = Data(buffer[0..<read])
            let from = QuicAddress(storage: storage, length: length)
            guard let header = QuicConnection.header(of: packet) else { continue }
            let existing = byID[header.destinationID]
            guard let key = existing ?? (header.isInitial ? accept(from: from, port: port) : nil),
                  let entry = entries[key] else { continue }
            // Every path is fed as arriving on the listener's own address: quiche keys paths by both addresses, and which socket carried a packet is this class's business, kept in `replyVia`.
            entry.connection.receive(packet, from: from, to: local)
            entry.lastHeard = .now
            noteArrival(of: entry, key: key, from: from, port: port, wasKnown: existing != nil)
            touched.insert(key)
        }
        for key in touched {
            guard let entry = entries[key] else { continue }
            serve(entry, key: key)
        }
    }

    private func noteArrival(of entry: Entry, key: ObjectIdentifier, from: QuicAddress, port: RelayPort?, wasKnown: Bool) {
        guard let port else {
            entry.replyVia[from] = nil
            return
        }
        entry.replyVia[from] = port.fd
        port.lastHeard = .now
        guard port.owner == nil else { return }
        port.owner = key
        if wasKnown {
            listenerLog.notice("a connection moved onto the relay")
            onRelayAdopted?(entry.link, port.route)
        }
    }

    private func accept(from peer: QuicAddress, port: RelayPort?) -> ObjectIdentifier? {
        guard !closed, let connection = try? QuicConnection.accept(local: local, peer: peer, configuration: configuration) else { return nil }
        let entryBox = EntryBox()
        let link = QuicFrameLink(carrier: QuicFrameLink.Carrier(
            queue: queue,
            flush: { [weak self] in
                guard let self, let entry = entryBox.entry as? Entry else { return }
                flush(entry)
            },
            cancel: { [weak self] in
                guard let self, let entry = entryBox.entry as? Entry else { return }
                remove(ObjectIdentifier(entry))
            },
            paths: { [weak self] in
                guard let self, let entry = entryBox.entry as? Entry else { return nil }
                return pathSockets(for: entry)
            }
        ), peerAddress: peer)
        let entry = Entry(connection: connection, link: link)
        entryBox.entry = entry
        let key = ObjectIdentifier(entry)
        entries[key] = entry
        registerIDs(of: entry, key: key)
        listenerLog.notice("a phone opened a QUIC connection from \(peer.description, privacy: .public)\(port == nil ? "" : " through the relay", privacy: .public)")
        onLink?(link, port?.route)
        return key
    }

    /// The relay port this connection uses most recently, which is where it knocks and keeps a route.
    private func pathSockets(for entry: Entry) -> QuicFrameLink.PathSockets {
        let key = ObjectIdentifier(entry)
        let port = ports.values.filter { $0.owner == key }.max { ($0.lastHeard ?? $0.opened) < ($1.lastHeard ?? $1.opened) }
        return QuicFrameLink.PathSockets(
            local: local,
            relay: port?.route.address,
            silence: entry.lastHeard.map { .now - $0 },
            knock: { [weak self] address in
                guard let self, let port else { return }
                // Through the relay port: the phone probes the address the relay saw for this Mac, which is that socket's mapping in the router.
                write(Data([0]), to: address, through: port.fd)
                entry.replyVia[address] = port.fd
            },
            refreshRelayBinding: { [weak self] in
                guard let self, let port else { return }
                bind(port)
            }
        )
    }

    private func serve(_ entry: Entry, key: ObjectIdentifier) {
        entry.link.activity(on: entry.connection)
        registerIDs(of: entry, key: key)
        flush(entry)
        if entry.connection.isClosed {
            remove(key)
            entry.link.closed()
        }
    }

    /// Picks up ids the connection issued since the last look (the spares a migration will use).
    private func registerIDs(of entry: Entry, key: ObjectIdentifier) {
        let ids = entry.connection.sourceIDs
        guard ids.count != entry.knownIDs else { return }
        for id in ids { byID[id] = key }
        entry.knownIDs = ids.count
    }

    private func flush(_ entry: Entry) {
        let pacer = entry.pacer ?? QuicPacer(queue: queue) { [weak self, weak entry] packet in
            // A paced packet can fall due after the listener closed its descriptor, whose number may already belong to another file.
            guard let self, let entry, !closed else { return }
            send(packet, for: entry)
        }
        entry.pacer = pacer
        pacer.submit(entry.connection.outgoing())
        entry.link.afterFlush()
        rearmTimer(entry)
    }

    private func send(_ packet: QuicConnection.Packet, for entry: Entry) {
        guard let viaFD = entry.replyVia[packet.destination], let port = ports[viaFD] else {
            write(packet.bytes, to: packet.destination, through: fd)
            return
        }
        // The relay forwards by the token in front; a peer reached directly through the same socket gets the packet bare.
        let bytes = packet.destination == port.route.address ? port.route.token + packet.bytes : packet.bytes
        write(bytes, to: packet.destination, through: port.fd)
    }

    private func write(_ bytes: Data, to destination: QuicAddress, through descriptor: Int32) {
        bytes.withUnsafeBytes { buffer in
            destination.withSockaddr { pointer, length in
                _ = sendto(descriptor, buffer.baseAddress, buffer.count, 0, pointer, length)
            }
        }
    }

    /// The token alone tells the relay where this port is.
    private func bind(_ port: RelayPort) {
        port.lastBound = .now
        write(port.route.token, to: port.route.address, through: port.fd)
    }

    private func rearmTimer(_ entry: Entry) {
        entry.timer?.cancel()
        entry.timer = nil
        guard let timeout = entry.connection.timeout else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)))
        let key = ObjectIdentifier(entry)
        timer.setEventHandler { [weak self] in
            guard let self, let entry = self.entries[key] else { return }
            entry.connection.onTimeout()
            serve(entry, key: key)
        }
        entry.timer = timer
        timer.resume()
    }

    private func remove(_ key: ObjectIdentifier) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.timer?.cancel()
        byID = byID.filter { $0.value != key }
        for port in ports.values where port.owner == key { close(port) }
    }

    // MARK: - Relay ports

    private func startHousekeeping() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.tendPorts() }
        housekeeping = timer
        timer.resume()
    }

    /// Keeps a port's relay route alive while its connection uses it, and closes ports nobody came to or that have fallen out of use.
    private func tendPorts(now: ContinuousClock.Instant = .now) {
        for port in ports.values {
            guard port.owner != nil else {
                if now - port.opened > Self.relayArrivalWindow { close(port) }
                continue
            }
            let idle = now - (port.lastHeard ?? port.opened)
            if idle > Self.relayDisuseLimit {
                close(port)
            } else if idle < Self.relayRefreshInterval * 2, now - port.lastBound >= Self.relayRefreshInterval {
                bind(port)
            }
        }
    }

    private func close(_ port: RelayPort) {
        ports[port.fd] = nil
        for entry in entries.values {
            entry.replyVia = entry.replyVia.filter { $0.value != port.fd }
        }
        port.source?.cancel()
    }
}

/// Lets a link's carrier closures reach the entry that owns the link without the link owning the entry.
private final class EntryBox: @unchecked Sendable {
    weak var entry: AnyObject?
}
