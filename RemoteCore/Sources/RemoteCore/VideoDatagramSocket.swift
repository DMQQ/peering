import CryptoKit
import Crypto
import Foundation
import Network
import Security

/// the relay will not forward to an address it has not been told about, and the bind is not a
/// formality: a NAT binding expires and a session that stops being forwarded to reports nothing, the
/// picture simply stops. Repeating the bind on a timer is what prevents that.
public final class VideoDatagramSocket: @unchecked Sendable {
    /// Classified by not being the relay rather than by matching a known peer: the Mac does not know
    /// the phone's address until a datagram arrives from it. A fact about addressing, not identity,
    /// since anyone able to write a source address can produce a `.peer` datagram, and who sent it is
    /// established by opening what arrived with the session key.
    public enum Source: Sendable, Equatable {
        case relay
        case peer(host: String, port: UInt16)
    }

    public static let keepaliveInterval: TimeInterval = 10

    /// How many datagrams may be held while the bind is still going out: sends made before the bind
    /// would reach the relay before it knows the address. Bounded, oldest first when full.
    static let maxHeldDatagrams = 32

    /// How recently the peer must have been heard from for the direct path to be believed live.
    /// Generous, because it has to survive a lull: a still screen sends far less, and a path declared
    /// dead during one would drop back to the relay and have to be punched again.
    public static let directPathIdleTimeout: TimeInterval = 12

    let queue: DispatchQueue
    let queueMarker = DispatchSpecificKey<Void>()
    let token: Data
    let fd: Int32
    let family: Int32

    let relayAddress: sockaddr_storage
    let relayLength: socklen_t

    var peerAddress: sockaddr_storage?
    var peerLength: socklen_t = 0

    var readSource: DispatchSourceRead?
    var bindTimer: DispatchSourceTimer?
    /// callers rather than one, because two kinds of send share this socket: the pump's, which must
    /// be told when its frames are away or it never sends another, and a probe's, which does not
    /// care.
    var held: [Held] = []
    var heldCount = 0
    var bound = false
    var stopped = false

    public var onDatagram: (@Sendable (Data, Source) -> Void)?
    public var onFailure: (@Sendable (Error) -> Void)?

    let counterLock = NSLock()
    var _sent = 0
    var _received = 0
    var _receivedFromPeer = 0

    public var sentDatagrams: Int { counterLock.withLock { _sent } }
    public var receivedDatagrams: Int { counterLock.withLock { _received } }
    /// How many datagrams arrived from the peer rather than the relay. A count rather than a flag,
    /// because a path that works for a second and then stops looks like success in a boolean.
    public var receivedFromPeer: Int { counterLock.withLock { _receivedFromPeer } }

    public var hasDirectPeer: Bool { onQueue { peerAddress != nil } }

    /// A plain `queue.sync` traps here: libdispatch aborts the process when the calling thread
    /// already owns the queue, and the receive path is one of the callers that enters this socket
    /// from the queue.
    func onQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueMarker) != nil {
            return try work()
        }
        return try queue.sync(execute: work)
    }

    public init(host: String, port: UInt16, token: Data, label: String) throws {
        guard token.count == VideoDatagram.tokenSize else {
            throw VideoDatagramError.invalidToken(bytes: token.count)
        }
        self.token = token
        queue = DispatchQueue(label: label)
        queue.setSpecific(key: queueMarker, value: ())

        // The relay's family decides the socket's, because the relay is the destination every
        // session has and the peer is the one that might not exist. IPv6 is preferred: two ends on
        // IPv6 need no hole punch. IPv4 is the fallback where there is no IPv6 reachability.
        guard let resolved = Self.resolveRacing(host: host, port: port) else {
            throw VideoDatagramError.unresolvedHost(host)
        }
        relayAddress = resolved.address
        relayLength = resolved.length
        family = Int32(resolved.address.ss_family)

        let descriptor = socket(family, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            throw VideoDatagramError.socketUnavailable(errno)
        }
        fd = descriptor

        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        var local = sockaddr_storage()
        let localLength = Self.wildcard(family: family, into: &local)
        let bound = withUnsafePointer(to: &local) { storage in
            storage.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, localLength)
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw VideoDatagramError.socketUnavailable(code)
        }

        // Read back rather than remembered, because the port is whatever the kernel handed out, and
        // the value only says which local port a session is sending from. What the relay reports is
        // the NAT mapping in front of it, which this end never learns and does not need to.
        var actual = sockaddr_storage()
        var actualLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        if withUnsafeMutablePointer(to: &actual, { storage in
            storage.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &actualLength)
            }
        }) == 0 {
            localPort = UInt16(bigEndian: withUnsafeBytes(of: actual) {
                $0.loadUnaligned(fromByteOffset: 2, as: UInt16.self)
            })
        }
    }

    public private(set) var localPort: UInt16 = 0

    /// There is no connected state to wait for here: a BSD socket is usable the moment it is bound,
    /// so the bind goes out immediately rather than on a state change that may never arrive.
    public func start() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }

            let source = DispatchSource.makeReadSource(fileDescriptor: self.fd, queue: self.queue)
            source.setEventHandler { [weak self] in self?.drain() }
            source.resume()
            self.readSource = source

            self.sendBind()
            self.startBindTimer()
        }
    }

    ///
    public func setDirectPeer(host: String, port: UInt16) throws {
        try onQueue {
            guard let resolved = Self.resolvePeer(host: host, port: port, family: family) else {
                throw VideoDatagramError.unusablePeerAddress(host)
            }
            peerAddress = resolved.address
            peerLength = resolved.length
        }
    }

    public func send(_ datagrams: [Data], completion: @escaping @Sendable (Error?) -> Void) {
        enqueue(datagrams, direct: false, completion: completion)
    }

    /// The probe's door: a path cannot be believed live before something has crossed it, so these
    /// datagrams go direct without the socket's own permission.
    public func sendDirect(
        _ datagrams: [Data],
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        guard hasDirectPeer else {
            completion(nil)
            return
        }
        enqueue(datagrams, direct: true, completion: completion)
    }

    public func cancel() {
        // Resource release is part of cancellation's contract, so it happens before returning, and
        // synchronously: a BSD descriptor is not managed by ARC, so letting deallocation release the
        // socket leaks it for the life of the process.
        onQueue { stopOnQueue() }
    }

    deinit {
        onQueue { stopOnQueue() }
    }

    // MARK: - All on `queue`

    var lastPeerAt: Date?


}
