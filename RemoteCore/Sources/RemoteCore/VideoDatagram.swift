// CryptoKit on Apple platforms; the open-source swift-crypto module is named `Crypto`. Same API
// either way, so the package stays dependency-free on Apple platforms without giving up portability.
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Network
import Security

/// The shape of a video datagram, in one place, because both ends and the relay all have to
/// agree about it.
///
/// ```
/// what an endpoint sends:   [ token 16 ][ counter 8 ][ ciphertext ][ tag 16 ]
/// what an endpoint gets:    [           counter 8 ][ ciphertext ][ tag 16 ]
/// ```
///
/// The relay strips the token before forwarding: it exists to tell the relay which session a datagram
/// belongs to and which end sent it, and is dead weight afterwards. An opener that expected one would
/// read the first eight bytes of a counter as somebody's identity.
///
/// A datagram that is only the token is a bind: it registers the sender's address with the relay
/// and is not forwarded. Both ends send one.
public enum VideoDatagram {
    /// The relay's video token, as `sessionReady` hands it out.
    public static let tokenSize = 16
    /// The AEAD nonce, in the clear, so the receiver can reconstruct it.
    public static let counterSize = 8
    /// ChaChaPoly's tag.
    public static let tagSize = 16

    /// The shortest forwarded datagram: a counter, an empty payload and a tag.
    public static let minForwardedSize = counterSize + tagSize

    /// The most this will read off a socket in one receive. Generous next to the largest datagram
    /// this ever sends and deliberately not 64 KB: as a buffer, nothing here needs more than a
    /// path MTU.
    public static let maxDatagramSize = 2 * 1024
}

public enum VideoDatagramError: Error, Equatable, Sendable {
    /// The datagram ended before the counter or the tag did.
    case truncated(have: Int, need: Int)
    /// The key does not open this datagram, or the bytes inside it are not what was sealed.
    ///
    /// An error rather than a dropped packet: this is the one signal that distinguishes the network
    /// losing video from two ends not speaking the same key, and swallowing it would leave a session
    /// with no picture and nothing to look at.
    case authenticationFailed
    /// The datagram opened and what came out was not a frame.
    case malformedPayload
    /// A token that is not the 16 bytes the relay's contract fixes it at.
    case invalidToken(bytes: Int)
    /// A port the relay supplied that is not a usable one.
    case invalidPort(UInt16)
    /// Larger than anything this protocol produces, and refused rather than opened.
    case oversized(bytes: Int)
    /// The relay's name did not resolve, so there is nowhere to send anything. Fatal at construction
    /// rather than at the first send, which would be after a session was announced as open.
    case unresolvedHost(String)
    /// The peer's address is not one this socket can use: a host string that does not parse, or one
    /// that answers only in the other address family. Not fatal and not reported to the user, since
    /// it means no direct path, the same outcome as a punch that fails.
    case unusablePeerAddress(String)
    /// The socket could not be created or bound.
    case socketUnavailable(Int32)
    /// A send failed for a reason that is not the ordinary lossiness of UDP.
    case sendFailed(Int32)
    /// A receive failed for a reason that is not the buffer being empty.
    case socketReadFailed(Int32)
}

extension VideoDatagramError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unresolvedHost(let host): return "Could not resolve the relay's address (\(host))."
        case .unusablePeerAddress(let host): return "The peer's address is not usable from this socket (\(host))."
        case .socketUnavailable(let code): return "The video socket could not be opened (\(code))."
        case .sendFailed(let code): return "Sending a video datagram failed (\(code))."
        case .socketReadFailed(let code): return "Reading the video socket failed (\(code))."
        default: return nil
        }
    }
}

/// Which way a sealed datagram is travelling. A direction rather than a role: neither end runs
/// different code, and only the key each holds distinguishes them.
public enum VideoDatagramDirection: Sendable, Equatable, CaseIterable {
    case clientToHost
    case hostToClient
}

/// The two keys one session's video datagrams are sealed with, derived from one secret.
///
/// Two keys rather than one because the counter is the AEAD nonce and it travels in the clear, so a
/// nonce may never repeat under a key: both ends counting from one under a single key would repeat
/// it on the first datagram of each direction. HKDF's `info` separates them, and the labels are
/// spelled out here so the two ends cannot drift into two derivations that both look correct.
public struct VideoKeySchedule: Sendable {
    /// How long the secret is: 32 bytes, the AEAD's key size. Sent inside the control channel's TLS
    /// session, so it is a session secret rather than a long-term one.
    public static let secretSize = 32

    /// The salt the derivation is bound to. A constant, not a random value: both ends have to
    /// produce the same keys from the same secret with nothing else exchanged.
    private static let salt = Data("pl.dmq.peering.video-datagram".utf8)

    private static let clientToHostLabel = "video client-to-host"
    private static let hostToClientLabel = "video host-to-client"

    private let secret: Data

    public init(secret: Data) {
        self.secret = secret
    }

    /// A fresh secret, or `nil` if the system would not give one.
    public static func randomSecret() -> Data? {
        var bytes = [UInt8](repeating: 0, count: secretSize)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return Data(bytes)
    }

    public func key(for direction: VideoDatagramDirection) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Self.salt,
            info: Data(Self.label(for: direction).utf8),
            outputByteCount: Self.secretSize
        )
    }

    private static func label(for direction: VideoDatagramDirection) -> String {
        switch direction {
        case .clientToHost: return clientToHostLabel
        case .hostToClient: return hostToClientLabel
        }
    }

    /// Seals what this end sends. Fails only for a token that is not the size the relay's
    /// contract fixes it at, which is a programming error rather than a runtime one.
    public func sealer(
        token: Data,
        direction: VideoDatagramDirection
    ) throws -> VideoDatagramSealer {
        try VideoDatagramSealer(key: key(for: direction), token: token)
    }

    /// Opens what the other end sent.
    public func opener(direction: VideoDatagramDirection) -> VideoDatagramOpener {
        VideoDatagramOpener(key: key(for: direction))
    }
}

/// The secret the Mac generates for one session, encoded into a ``MessageKind/videoKey`` frame.
///
/// It travels inside the control channel, a TLS session with pinned identities on both sides, so it
/// is not encrypted again here: the relay terminates neither end and never sees it.
public struct VideoKeyGrant: Codable, Sendable, Equatable {
    public let secret: Data

    public init(secret: Data) {
        self.secret = secret
    }
}

/// The replay window a video datagram has to fall inside to be opened.
///
/// Video arrives out of order by design, so the rule is not "greater than the last one": what is
/// rejected is a counter already seen, and one so far behind the newest that it cannot be told from
/// a replay. Ascending counters would throw away exactly the packets that were merely reordered.
///
/// The window is a bitmap over the last ``size`` counters: the newest is bit 0, each higher bit is
/// one older. Sixty-four deep, because a datagram reordered past that is a second of pictures old.
public struct VideoReplayWindow: Sendable {
    public static let size = 64

    private var highest: UInt64 = 0
    private var seen: UInt64 = 0
    private var started = false

    public init() {}

    /// Whether this counter is one that should be attempted.
    ///
    /// Checked before the datagram is authenticated, and non-mutating: a forged datagram with a huge
    /// counter would otherwise drag the window forward and reject every genuine packet behind it.
    public func accepts(_ counter: UInt64) -> Bool {
        guard started else { return true }
        guard counter <= highest else { return true }
        let distance = highest - counter
        guard distance < UInt64(Self.size) else { return false }
        return seen & (1 << UInt64(distance)) == 0
    }

    /// Records a counter that authenticated, which is the only point at which one may be.
    public mutating func commit(_ counter: UInt64) {
        guard started else {
            started = true
            highest = counter
            seen = 1
            return
        }

        if counter > highest {
            let shift = counter - highest
            // A jump wider than the window leaves nothing in it worth remembering, so the
            // bitmap starts again rather than pretending to know about counters it never saw.
            seen = shift >= UInt64(Self.size) ? 0 : seen << shift
            seen |= 1
            highest = counter
        } else {
            seen |= 1 << (highest - counter)
        }
    }

    /// Forgets everything. A new session's counters start from nothing and say nothing about the
    /// last session's.
    public mutating func reset() {
        highest = 0
        seen = 0
        started = false
    }
}

/// Cuts a video payload into datagrams and seals each one.
///
/// 1024-byte chunks rather than the control channel's 16 KB, because a datagram is one packet: a
/// 16 KB chunk would be eleven fragments on a 1500-byte path and would lose the whole picture to
/// any one of them. At ``VideoChunk/maxDatagramPayload`` a sealed datagram is about 1080 bytes,
/// which stays under the 1280-byte minimum MTU of IPv6. The chunking is ``VideoChunkEncoder``'s, so
/// a payload travelling a datagram here and a control message there is cut by the same code.
public struct VideoDatagramSealer: Sendable {
    private let key: SymmetricKey
    private let token: Data
    private var counter: UInt64 = 0
    /// Distinguishes the chunks of one payload from the next, as it does on the control lane.
    private var frameID: UInt32 = 0

    public init(key: SymmetricKey, token: Data) throws {
        guard token.count == VideoDatagram.tokenSize else {
            throw VideoDatagramError.invalidToken(bytes: token.count)
        }
        self.key = key
        self.token = token
    }

    /// The datagrams one payload becomes, each carrying its own counter.
    ///
    /// An empty result means the payload could not be sealed or was larger than the chunk header
    /// can count; either way nothing goes on the wire.
    public mutating func seal(kind: MessageKind, payload: Data) -> [Data] {
        frameID &+= 1
        let pieces = VideoChunkEncoder.encode(
            kind: kind,
            payload: payload,
            frameID: frameID,
            chunkSize: VideoChunk.maxDatagramPayload
        )

        var datagrams: [Data] = []
        datagrams.reserveCapacity(pieces.count)
        for piece in pieces {
            let next = counter &+ 1
            guard let nonce = Self.nonce(next),
                  let box = try? ChaChaPoly.seal(FrameEncoder.encode(piece), using: key, nonce: nonce)
            else { return [] }
            counter = next

            var datagram = Data(capacity: token.count + VideoDatagram.counterSize + box.ciphertext.count + VideoDatagram.tagSize)
            datagram.append(token)
            datagram.appendBigEndian(next)
            datagram.append(box.ciphertext)
            datagram.append(box.tag)
            datagrams.append(datagram)
        }
        return datagrams
    }

    /// The 12 bytes ChaChaPoly wants, built from the 8 the wire carries: four leading zeros and the
    /// counter, big-endian. The counter is the whole of the nonce's entropy and never repeats under
    /// a key, which is why the two directions need two keys.
    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce? {
        var bytes = Data([0, 0, 0, 0])
        bytes.appendBigEndian(counter)
        return try? ChaChaPoly.Nonce(data: bytes)
    }
}

/// Opens sealed datagrams and puts the payloads inside them back together.
///
/// One of these per lane. Two lanes carry video at once while the client is in fallback, the
/// datagram lane and the control channel; they interleave on the wire and their chunk numbering is
/// independent, so a reassembler shared between them would read the other lane's chunks as a newer
/// picture and abandon the one it was assembling.
public struct VideoDatagramOpener {
    private let key: SymmetricKey
    private var window = VideoReplayWindow()
    private var chunks = VideoChunkReassembler()

    public init(key: SymmetricKey) {
        self.key = key
    }

    /// The whole frame this datagram completed, or `nil` when it carried a piece of one or was one
    /// the window refused.
    ///
    /// A `nil` return is the ordinary case rather than a failure: a large picture arrives as twenty
    /// datagrams and only the last of them completes it. Anything genuinely wrong throws.
    public mutating func open(_ datagram: Data) throws -> Frame? {
        guard datagram.count >= VideoDatagram.minForwardedSize else {
            throw VideoDatagramError.truncated(have: datagram.count, need: VideoDatagram.minForwardedSize)
        }
        // A datagram is at most a path MTU in this protocol, so one that claims otherwise came from
        // something that is not a peer running it. Refused before any of it is parsed.
        guard datagram.count <= VideoDatagram.maxDatagramSize else {
            throw VideoDatagramError.oversized(bytes: datagram.count)
        }

        // Normalised because the caller's data may be a slice of a receive buffer, and every
        // offset below is read from the start of the datagram rather than from its storage.
        let body = Data(datagram)
        let counter = body.readBigEndianUInt64(at: 0)
        guard window.accepts(counter) else { return nil }

        let tagStart = body.count - VideoDatagram.tagSize
        guard let nonce = VideoDatagramSealer.nonce(counter),
              let box = try? ChaChaPoly.SealedBox(
                  nonce: nonce,
                  ciphertext: body[VideoDatagram.counterSize..<tagStart],
                  tag: body[tagStart...]
              ),
              let plaintext = try? ChaChaPoly.open(box, using: key)
        else {
            throw VideoDatagramError.authenticationFailed
        }

        // Only now, having proved the datagram came from the peer, does it move the window. See
        // ``VideoReplayWindow/accepts(_:)``.
        window.commit(counter)

        var decoder = FrameDecoder()
        decoder.append(plaintext)
        guard let decoded = try? decoder.next() else {
            throw VideoDatagramError.malformedPayload
        }

        guard decoded.kind == .videoChunk else { return decoded }
        do {
            return try chunks.ingest(decoded)
        } catch {
            throw VideoDatagramError.malformedPayload
        }
    }

    /// Forgets the window and the partial picture being assembled.
    public mutating func reset() {
        window.reset()
        chunks = VideoChunkReassembler()
    }
}

/// The UDP socket one end of a session sends and receives video datagrams on.
///
/// One class for both ends, which differ only in which half they use. Both have to bind, because
/// the relay will not forward to an address it has not been told about, and the bind is not a
/// formality: a NAT binding expires and a session that stops being forwarded to reports nothing, the
/// picture simply stops. Repeating the bind on a timer is what prevents that.
public final class VideoDatagramSocket: @unchecked Sendable {
    /// Where an arriving datagram came from.
    ///
    /// Classified by not being the relay rather than by matching a known peer: the Mac does not know
    /// the phone's address until a datagram arrives from it. A fact about addressing, not identity,
    /// since anyone able to write a source address can produce a `.peer` datagram, and who sent it is
    /// established by opening what arrived with the session key.
    public enum Source: Sendable, Equatable {
        /// The relay. Every session starts here, and most stay here for their whole life.
        case relay
        /// Straight from the other end, at this address.
        case peer(host: String, port: UInt16)
    }

    /// How often the bind is repeated. Well inside the shortest UDP timeout anyone deploys, and
    /// sixteen bytes against a video stream measured in megabits.
    public static let keepaliveInterval: TimeInterval = 10

    /// How many datagrams may be held while the bind is still going out: sends made before the bind
    /// would reach the relay before it knows the address. Bounded, oldest first when full.
    private static let maxHeldDatagrams = 32

    /// How recently the peer must have been heard from for the direct path to be believed live.
    /// Generous, because it has to survive a lull: a still screen sends far less, and a path declared
    /// dead during one would drop back to the relay and have to be punched again.
    public static let directPathIdleTimeout: TimeInterval = 12

    /// Named by the caller: the two ends run the same code, and a stack trace should say which.
    private let queue: DispatchQueue
    /// Set on ``queue``, so a call arriving from the queue can tell that it is already on it. See
    /// ``onQueue(_:)``.
    private let queueMarker = DispatchSpecificKey<Void>()
    private let token: Data
    /// The descriptor, and the address family it was created in: a peer answering only in the other
    /// one cannot be reached from here, and saying so beats a `sendto` that fails on every attempt.
    private let fd: Int32
    private let family: Int32

    /// The relay, resolved once at init because every send needs it and nothing about it changes.
    private let relayAddress: sockaddr_storage
    private let relayLength: socklen_t

    /// Where the peer is, once the relay has said. While it is `nil`, no direct path is attempted
    /// at all.
    private var peerAddress: sockaddr_storage?
    private var peerLength: socklen_t = 0

    private var readSource: DispatchSourceRead?
    private var bindTimer: DispatchSourceTimer?
    /// Datagrams waiting for the bind, each with the caller that is waiting for them. A list of
    /// callers rather than one, because two kinds of send share this socket: the pump's, which must
    /// be told when its frames are away or it never sends another, and a probe's, which does not
    /// care.
    private var held: [Held] = []
    private var heldCount = 0
    private var bound = false
    private var stopped = false

    /// Set before ``start()``. A datagram that arrived, with the relay's token prefix already
    /// stripped and nothing else done to it, and where it came from.
    public var onDatagram: (@Sendable (Data, Source) -> Void)?
    /// Set before ``start()``. Called for a socket that failed, and on every send that fails.
    public var onFailure: (@Sendable (Error) -> Void)?

    /// Counters for the diagnostics panel. Written on ``queue``, read from anywhere.
    private let counterLock = NSLock()
    private var _sent = 0
    private var _received = 0
    private var _receivedFromPeer = 0

    public var sentDatagrams: Int { counterLock.withLock { _sent } }
    public var receivedDatagrams: Int { counterLock.withLock { _received } }
    /// How many datagrams arrived from the peer rather than the relay. A count rather than a flag,
    /// because a path that works for a second and then stops looks like success in a boolean.
    public var receivedFromPeer: Int { counterLock.withLock { _receivedFromPeer } }

    /// Whether a peer has been set, which is what makes ``sendDirect(_:completion:)`` meaningful.
    public var hasDirectPeer: Bool { onQueue { peerAddress != nil } }

    /// Runs `work` on ``queue``, or right here when the caller is already on it.
    ///
    /// A plain `queue.sync` traps here: libdispatch aborts the process when the calling thread
    /// already owns the queue, and the receive path is one of the callers that enters this socket
    /// from the queue.
    private func onQueue<T>(_ work: () throws -> T) rethrows -> T {
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
        // Set before anything can run on it, so ``onQueue(_:)`` can tell a call made from inside the
        // queue from one made outside it.
        queue.setSpecific(key: queueMarker, value: ())

        // The relay's family decides the socket's, because the relay is the destination every
        // session has and the peer is the one that might not exist. IPv6 is preferred: two ends on
        // IPv6 need no hole punch. IPv4 is the fallback where there is no IPv6 reachability.
        guard let resolved = Self.resolve(host: host, port: port, family: AF_INET6, numeric: false)
                           ?? Self.resolve(host: host, port: port, family: AF_INET, numeric: false)
        else {
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

        // Non-blocking, so the read source drains what has arrived and returns rather than parking a
        // thread on a socket that is idle for most of its life.
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        // Bound to the family's wildcard and port zero: the kernel picks the port, the NAT builds a
        // mapping for it, and the relay reports what that mapping turned out to be. This address is
        // what the whole direct path is built on.
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

    /// The local port this socket bound, or 0 if it could not be read back.
    ///
    /// The port on this side of any NAT, not the address the relay reports, which is the mapping in
    /// front of it. It says nothing about where the session can be reached from.
    public private(set) var localPort: UInt16 = 0

    /// Opens the socket, binds, and keeps the binding alive until ``cancel()``.
    ///
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

    /// Points the socket at the other end, so datagrams can go straight there.
    ///
    /// Throws when the address cannot be used from this socket: a peer that answers only in the
    /// other address family, or a host string that does not parse. Either way the caller gets no
    /// direct path, and the session stays on the relay, as it does when a punch fails.
    public func setDirectPeer(host: String, port: UInt16) throws {
        try onQueue {
            guard let resolved = Self.resolvePeer(host: host, port: port, family: family) else {
                throw VideoDatagramError.unusablePeerAddress(host)
            }
            peerAddress = resolved.address
            peerLength = resolved.length
        }
    }

    /// Sends the datagrams one payload became, by whichever path is currently the better one.
    ///
    /// The completion drives the sender's flow control, one item in flight at a time, so it is
    /// called for the whole group rather than per datagram, and a group held waiting for the bind
    /// reports once it has actually been sent. The choice of path is made here rather than by the
    /// caller: every sender above already knows how to send, and only the address changes.
    public func send(_ datagrams: [Data], completion: @escaping @Sendable (Error?) -> Void) {
        enqueue(datagrams, direct: false, completion: completion)
    }

    /// Sends to the peer explicitly, whether or not the path is yet believed live.
    ///
    /// The probe's door: a path cannot be believed live before something has crossed it, so these
    /// datagrams go direct without the socket's own permission.
    ///
    /// The token is not stripped here: stripping belongs where the destination is known, which is
    /// ``enqueue(_:direct:completion:)``. Does nothing when no peer has been set.
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
        // `cancel()` is the normal path; this is the backstop for a socket constructed and then
        // released before its owner had a chance to start it.
        onQueue { stopOnQueue() }
    }

    // MARK: - All on `queue`

    /// Where a group of datagrams is going.
    private enum Destination: Equatable {
        case relay
        case peer
    }

    /// One held group, remembering the destination chosen for it. Remembered rather than recomputed
    /// at the flush: a group held before the bind was chosen for the path as it stood then, and
    /// re-deciding later would move a session's first frames onto a path not yet proved.
    private struct Held {
        let datagrams: [Data]
        let destination: Destination
        let completion: (@Sendable (Error?) -> Void)?
    }

    /// When a datagram was last seen arriving from the peer, and whether one ever has.
    private var lastPeerAt: Date?

    /// Whether the direct path is believed to be carrying the session, on the queue.
    ///
    /// Belief, not proof, and the whole of the switching rule: live while the peer has been heard
    /// from recently, dead the moment it has not, with nothing negotiated or signalled, so the
    /// fallback to the relay is automatic rather than a recovery path somebody has to trigger.
    private var directPathIsLive: Bool {
        guard peerAddress != nil, let last = lastPeerAt else { return false }
        return Date().timeIntervalSince(last) < Self.directPathIdleTimeout
    }

    /// Reads everything that has arrived and returns, rather than parking on the descriptor.
    ///
    /// The loop is what makes one read source serve a burst: a dispatch source fires once when the
    /// socket becomes readable, and a picture arriving as forty datagrams is one event and forty
    /// reads. It stops on `EAGAIN`, which is the buffer being empty rather than a failure.
    private func drain() {
        guard !stopped else { return }
        var buffer = [UInt8](repeating: 0, count: VideoDatagram.maxDatagramSize)

        while true {
            var from = sockaddr_storage()
            var fromLength = socklen_t(MemoryLayout<sockaddr_storage>.size)

            let read: Int = withUnsafeMutablePointer(to: &from) { storage in
                storage.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                    buffer.withUnsafeMutableBytes { bytes -> Int in
                        guard let base = bytes.baseAddress else { return -1 }
                        return recvfrom(fd, base, bytes.count, 0, pointer, &fromLength)
                    }
                }
            }

            if read < 0 {
                if errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                    onFailure?(VideoDatagramError.socketReadFailed(errno))
                }
                return
            }
            guard read > 0 else { return }

            let source: Source
            if Self.sameAddress(from, relayAddress) {
                source = .relay
            } else if let origin = Self.describe(from, length: fromLength) {
                source = .peer(host: origin.host, port: origin.port)
            } else {
                // An address that cannot be named is one this end could not send back to, so it is
                // not a path however it arrived, and it counts with the relay's traffic.
                source = .relay
            }

            let fromPeer = source != .relay
            counterLock.withLock {
                _received += 1
                if fromPeer { _receivedFromPeer += 1 }
            }
            if fromPeer { lastPeerAt = Date() }
            onDatagram?(Data(buffer[0..<read]), source)
        }
    }

    private func enqueue(
        _ datagrams: [Data],
        direct: Bool,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        guard !datagrams.isEmpty else {
            completion(nil)
            return
        }
        queue.async { [weak self] in
            guard let self, !self.stopped else {
                completion(nil)
                return
            }
            // Chosen here, on the queue, rather than by the caller: every sender above already knows
            // how to send, and only the address changes with a direct path.
            let destination: Destination = direct || self.directPathIsLive ? .peer : .relay

            // The token comes off exactly when the datagram is not going to the relay, and here
            // rather than in the caller, because this is the only place that knows where it is
            // going: the relay needs the token, and a peer reading it as a counter refuses every
            // datagram, which looks exactly like a lossy path.
            let payloads = destination == .peer
                ? datagrams.map { $0.dropFirst(VideoDatagram.tokenSize) }
                : datagrams

            guard self.bound else {
                // Waiting for the bind. The oldest goes when the queue is full: a stale picture is
                // worth less than the one that just arrived.
                self.held.append(Held(
                    datagrams: payloads,
                    destination: destination,
                    completion: completion
                ))
                self.heldCount += payloads.count
                // The newest is always kept, even alone larger than the cap: it is the picture the
                // client has not seen, and the ones being dropped are not.
                while self.heldCount > Self.maxHeldDatagrams, self.held.count > 1 {
                    self.heldCount -= self.held.removeFirst().datagrams.count
                }
                return
            }
            self.write(payloads, to: destination, completion: completion)
        }
    }

    /// Registers this address with the relay and tells it which session the address belongs to.
    /// Sixteen bytes and no payload: everything after the token would be forwarded.
    ///
    /// Always to the relay, even once a direct path is carrying the picture: a direct path is built
    /// on that address rather than instead of it, so a punch that later stopped working still has
    /// somewhere to fall back to.
    private func sendBind() {
        write([token], to: .relay) { [weak self] error in
            guard let self else { return }
            if let error {
                // The bind is the one send that has to work: without it the relay has nowhere to
                // forward from, and every send after it would be held waiting for a bind that is
                // not coming, which is a pump that never runs again rather than a dropped picture.
                // So the socket is closed instead.
                self.onFailure?(error)
                self.stopOnQueue()
                return
            }
            self.bound = true
            self.flushHeld()
        }
    }

    /// Closes the socket and releases everyone waiting on it. Call on `queue`.
    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        bindTimer?.cancel()
        bindTimer = nil
        let waiting = held
        held.removeAll()
        heldCount = 0
        readSource?.cancel()
        readSource = nil
        // The descriptor is this class's to close: leaving it open would hold the local port, and
        // with it the NAT mapping the relay still has on record, for the life of the process.
        close(fd)
        for entry in waiting { entry.completion?(nil) }
    }

    private func flushHeld() {
        guard !held.isEmpty else { return }
        let waiting = held
        held.removeAll(keepingCapacity: true)
        heldCount = 0

        // Grouped by destination, because one flush can straddle both: the frames held before a bind
        // went to the relay, and the path may have been proved by the time the bind lands. Each
        // group is a single write, so every caller in it is told the same moment.
        for destination in [Destination.relay, .peer] {
            let group = waiting.filter { $0.destination == destination }
            guard !group.isEmpty else { continue }
            write(group.flatMap(\.datagrams), to: destination) { error in
                for entry in group { entry.completion?(error) }
            }
        }
    }

    /// The one place a datagram is actually handed to the kernel.
    ///
    /// A full send buffer is not reported as a failure: datagrams are already allowed to be lost,
    /// and calling "would block" an error would tear down a session over a busy link.
    private func write(
        _ datagrams: [Data],
        to destination: Destination,
        completion: (@Sendable (Error?) -> Void)?
    ) {
        var address = destination == .peer ? (peerAddress ?? relayAddress) : relayAddress
        let peerIsSet = peerAddress != nil
        let length = destination == .peer && peerIsSet ? peerLength : relayLength

        var failure: Error?
        for datagram in datagrams {
            let result: Int = datagram.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return withUnsafePointer(to: &address) { storage in
                    storage.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                        sendto(fd, base, bytes.count, 0, pointer, length)
                    }
                }
            }
            if result < 0, errno != EAGAIN, errno != EWOULDBLOCK, failure == nil {
                failure = VideoDatagramError.sendFailed(errno)
            }
        }

        counterLock.withLock { _sent += datagrams.count }
        if let failure { onFailure?(failure) }
        completion?(failure)
    }

    private func startBindTimer() {
        guard bindTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.keepaliveInterval,
            repeating: Self.keepaliveInterval,
            leeway: .seconds(1)
        )
        // The bind, not a sealed datagram: it is the address the relay remembers, and the video
        // itself keeps the other direction's mapping warm simply by existing.
        timer.setEventHandler { [weak self] in self?.sendBind() }
        timer.resume()
        bindTimer = timer
    }

    // MARK: - Addressing

    /// Whether two socket addresses are the same host and port.
    ///
    /// Only the port and the address are compared, not the whole structure: the kernel writes a
    /// length and padding into the storage that a resolved address does not carry, so a
    /// byte-for-byte comparison would call the peer a stranger every time.
    private static func sameAddress(_ lhs: sockaddr_storage, _ rhs: sockaddr_storage?) -> Bool {
        guard let rhs, lhs.ss_family == rhs.ss_family else { return false }

        return withUnsafeBytes(of: lhs) { left in
            withUnsafeBytes(of: rhs) { right in
                let leftPort = left.loadUnaligned(fromByteOffset: 2, as: UInt16.self)
                let rightPort = right.loadUnaligned(fromByteOffset: 2, as: UInt16.self)
                guard leftPort == rightPort else { return false }

                switch Int32(lhs.ss_family) {
                case AF_INET:
                    return left.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
                        == right.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
                case AF_INET6:
                    return left.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
                        == right.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
                        && left.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
                            == right.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
                default:
                    return false
                }
            }
        }
    }

    /// The host and port a received address holds, as text.
    ///
    /// `NI_NUMERICHOST`, so an address goes back out exactly as it came in and no name is ever
    /// looked up on a value that arrived over the network.
    private static func describe(
        _ address: sockaddr_storage,
        length: socklen_t
    ) -> (host: String, port: UInt16)? {
        var storage = address
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var service = [CChar](repeating: 0, count: Int(NI_MAXSERV))

        let result = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo(
                    $0, length,
                    &host, socklen_t(host.count),
                    &service, socklen_t(service.count),
                    NI_NUMERICHOST | NI_NUMERICSERV
                )
            }
        }
        guard result == 0 else { return nil }
        func decoded(_ buffer: [CChar]) -> String {
            let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
        return (decoded(host), UInt16(decoded(service)) ?? 0)
    }

    /// The peer's address, said in the family this socket was built in.
    ///
    /// macOS resolves an IPv4-only name asked for under `AF_INET6` to its v4-mapped form, so a socket
    /// aimed at a relay with an `A` record and no `AAAA` is built in `AF_INET6`, while the relay names
    /// the peer in `AF_INET`. `getaddrinfo` refuses a plain IPv4 literal for an `AF_INET6` socket, so
    /// the peer is spelled as `::ffff:` plus the literal. Fold on the way out, map on the way in.
    ///
    /// A v6 peer on a v4 socket is still refused: there is no way to say an IPv6 address from an
    /// `AF_INET` socket, and the relay does not offer that pair, since it compares families first.
    private static func resolvePeer(
        host: String,
        port: UInt16,
        family: Int32
    ) -> (address: sockaddr_storage, length: socklen_t)? {
        if let resolved = resolve(host: host, port: port, family: family, numeric: true) {
            return resolved
        }
        guard family == AF_INET6 else { return nil }
        // Spelled rather than assembled byte by byte: `::ffff:` and an IPv4 literal is itself a valid
        // IPv6 numeric address, so the resolver does the work and there is no prefix to get wrong. A
        // host that is not an address at all fails here, which is the correct answer.
        return resolve(host: "::ffff:\(host)", port: port, family: AF_INET6, numeric: true)
    }

    /// Resolves `host` and `port` into a socket address, restricted to `family`.
    ///
    /// `numeric` is for the peer, which the relay hands over as a literal: a name arriving from a
    /// server and going into a resolver is how a signalling service points a session where it likes.
    private static func resolve(
        host: String,
        port: UInt16,
        family: Int32,
        numeric: Bool
    ) -> (address: sockaddr_storage, length: socklen_t)? {
        var hints = addrinfo()
        hints.ai_family = family
        hints.ai_socktype = SOCK_DGRAM
        if numeric { hints.ai_flags = AI_NUMERICHOST }

        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else {
            return nil
        }
        defer { freeaddrinfo(info) }
        guard let addr = first.pointee.ai_addr, first.pointee.ai_addrlen > 0 else { return nil }

        var storage = sockaddr_storage()
        memcpy(&storage, addr, Int(first.pointee.ai_addrlen))
        return (storage, first.pointee.ai_addrlen)
    }

    /// The wildcard address for a family, so the kernel picks the port: whatever it hands back is
    /// what the NAT builds a mapping for, so a port chosen here would have no relationship to the
    /// address the direct path depends on.
    private static func wildcard(family: Int32, into storage: inout sockaddr_storage) -> socklen_t {
        switch family {
        case AF_INET6:
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = 0
            address.sin6_addr = in6addr_any
            memcpy(&storage, &address, MemoryLayout<sockaddr_in6>.size)
            return socklen_t(MemoryLayout<sockaddr_in6>.size)
        default:
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: INADDR_ANY)
            memcpy(&storage, &address, MemoryLayout<sockaddr_in>.size)
            return socklen_t(MemoryLayout<sockaddr_in>.size)
        }
    }
}
