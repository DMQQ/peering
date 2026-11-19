import Darwin
import Foundation
import os

private let listenerLog = Logger(subsystem: "pl.dmq.peering", category: "quic")

/// One UDP port serving any number of QUIC connections, each handed out as a ``QuicFrameLink``: the Mac's LAN listener. A packet goes to the connection whose ids include its destination id; an Initial for an unknown id opens a new one.
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
    private var closed = false

    private final class Entry {
        let connection: QuicConnection
        let link: QuicFrameLink
        var timer: DispatchSourceTimer?
        var knownIDs = 0

        init(connection: QuicConnection, link: QuicFrameLink) {
            self.connection = connection
            self.link = link
        }
    }

    /// A new connection's link, before its handshake finishes; called on `queue`.
    public var onLink: (@Sendable (QuicFrameLink) -> Void)?

    public enum Failure: Error {
        case socket(Int32)
    }

    public init(port: UInt16, configuration: QuicConfiguration, label: String) throws {
        let (fd, local) = try QuicEndpoint.openSocket(port: port)
        self.fd = fd
        self.local = local
        self.configuration = configuration
        queue = DispatchQueue(label: label)
        queue.async { [self] in startReading() }
    }

    public var localPort: UInt16 { local.port }

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
        var touched: Set<ObjectIdentifier> = []
        while true {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let read = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, MSG_DONTWAIT, $0, &length) }
            }
            guard read > 0 else { break }
            let packet = Data(buffer[0..<read])
            let from = QuicAddress(storage: storage, length: length)
            guard let header = QuicConnection.header(of: packet) else { continue }
            guard let key = byID[header.destinationID] ?? (header.isInitial ? accept(from: from) : nil),
                  let entry = entries[key] else { continue }
            entry.connection.receive(packet, from: from, to: local)
            touched.insert(key)
        }
        for key in touched {
            guard let entry = entries[key] else { continue }
            serve(entry, key: key)
        }
    }

    private func accept(from peer: QuicAddress) -> ObjectIdentifier? {
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
            }
        ), peerAddress: peer)
        let entry = Entry(connection: connection, link: link)
        entryBox.entry = entry
        let key = ObjectIdentifier(entry)
        entries[key] = entry
        registerIDs(of: entry, key: key)
        listenerLog.notice("a phone opened a QUIC connection from \(peer.description, privacy: .public)")
        onLink?(link)
        return key
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
        for packet in entry.connection.outgoing() {
            packet.bytes.withUnsafeBytes { bytes in
                packet.destination.withSockaddr { pointer, length in
                    _ = sendto(fd, bytes.baseAddress, bytes.count, 0, pointer, length)
                }
            }
        }
        entry.link.afterFlush()
        rearmTimer(entry)
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
    }
}

/// Lets a link's carrier closures reach the entry that owns the link without the link owning the entry.
private final class EntryBox: @unchecked Sendable {
    weak var entry: AnyObject?
}
