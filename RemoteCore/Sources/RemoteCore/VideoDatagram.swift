// CryptoKit is the system framework on Apple platforms; the open-source swift-crypto
// module is named `Crypto`. Same API either way, so the package stays dependency-free
// on Apple platforms without giving up portability.
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Network
import Security

/// The shape of a video datagram, in one place, because both ends and the relay all have to
/// agree about it and two of the three are in this repository.
///
/// ```
/// what an endpoint sends:   [ token 16 ][ counter 8 ][ ciphertext ][ tag 16 ]
/// what an endpoint gets:    [           counter 8 ][ ciphertext ][ tag 16 ]
/// ```
///
/// The relay strips the token before forwarding, which is why the two lines differ: the token
/// exists to tell the relay which session a datagram belongs to and which end sent it, and
/// once that has been decided it is dead weight. The receiving end therefore never sees a
/// token, and an opener that expected one would be reading the first eight bytes of a counter
/// as somebody's identity.
///
/// A datagram that is *only* the token is a bind: it registers the sender's address with the
/// relay and is not forwarded. Both ends send one.
public enum VideoDatagram {
    /// The relay's video token, as `sessionReady` hands it out.
    public static let tokenSize = 16
    /// The AEAD nonce, in the clear, so the receiver can reconstruct it.
    public static let counterSize = 8
    /// ChaChaPoly's tag.
    public static let tagSize = 16

    /// The shortest forwarded datagram: a counter, an empty payload and a tag.
    public static let minForwardedSize = counterSize + tagSize

    /// The most this will read off a socket in one receive.
    ///
    /// Generous next to the largest datagram this ever sends, and deliberately not 64 KB:
    /// a socket that will buffer anything is a socket that will buffer whatever is thrown
    /// at it, and nothing here needs more than a path MTU.
    public static let maxDatagramSize = 2 * 1024
}

public enum VideoDatagramError: Error, Equatable, Sendable {
    /// The datagram ended before the counter or the tag did.
    case truncated(have: Int, need: Int)
    /// The key does not open this datagram, or the bytes inside it are not what was sealed.
    ///
    /// **This is an error rather than a dropped packet on purpose.** A datagram that does not
    /// authenticate is the one signal that distinguishes "the network is losing video" from
    /// "these two ends are not speaking the same key", and those two have completely
    /// different answers. Swallowing it would leave a session with no picture, no log line and
    /// no reason to look for one.
    case authenticationFailed
    /// The datagram opened and what came out was not a frame.
    case malformedPayload
    /// A token that is not the 16 bytes the relay's contract fixes it at.
    case invalidToken(bytes: Int)
    /// A port the relay supplied that is not a usable one.
    case invalidPort(UInt16)
    /// Larger than anything this protocol produces, and refused rather than opened.
    case oversized(bytes: Int)
}

/// Which way a sealed datagram is travelling.
///
/// A direction rather than a role: neither end runs different code, and the only thing that
/// distinguishes them is which of the two keys below they hold.
public enum VideoDatagramDirection: Sendable, Equatable, CaseIterable {
    case clientToHost
    case hostToClient
}

/// The two keys one session's video datagrams are sealed with, derived from one secret.
///
/// **Two keys, one secret, and the split is not decoration.** The counter is the AEAD nonce
/// and it is in the clear, so a nonce may never repeat under a key. If both directions sealed
/// with one key, both ends would start counting at one and the very first datagram of each
/// direction would carry the same nonce under the same key — the one thing a stream cipher
/// must never do. HKDF's `info` parameter is what separates them, and the labels are spelled
/// out here rather than at the call sites so the two ends cannot drift into two different
/// derivations that both look correct.
public struct VideoKeySchedule: Sendable {
    /// How long the secret is. Sent inside the control channel's TLS session, so it is a
    /// session secret rather than a long-term one — 32 bytes is the AEAD's key size.
    public static let secretSize = 32

    /// The salt the derivation is bound to. A constant, not a random value: both ends have to
    /// produce the same keys from the same secret with nothing else exchanged, and a salt that
    /// travelled would be one more field to get wrong.
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
/// It travels inside the control channel, which is a TLS session between the two ends with
/// pinned identities on both sides, so it is not encrypted again here: the relay terminates
/// neither end of that connection and never sees this. What the relay forwards afterwards is
/// ciphertext it has no key for.
public struct VideoKeyGrant: Codable, Sendable, Equatable {
    public let secret: Data

    public init(secret: Data) {
        self.secret = secret
    }
}

/// The replay window a video datagram has to fall inside to be opened.
///
/// **Video arrives out of order by design, so "greater than the last one" is the wrong rule.**
/// Two datagrams that swap places in a queue is ordinary on any path with more than one hop,
/// and a receiver that insisted on ascending counters would throw away exactly the packets
/// that were merely reordered — turning a healthy path into a picture with a hole in every
/// frame. What is rejected is a counter that has already been *seen*, and one so far behind
/// the newest that it cannot be told from a replay.
///
/// The window is a bitmap over the last ``size`` counters: the newest is bit 0, and each
/// higher bit is one older. Sixty-four deep because a datagram reordered by more than that
/// on a video path has been overtaken by a whole second of pictures and is worthless anyway.
public struct VideoReplayWindow: Sendable {
    public static let size = 64

    private var highest: UInt64 = 0
    private var seen: UInt64 = 0
    private var started = false

    public init() {}

    /// Whether this counter is one that should be attempted.
    ///
    /// Checked *before* the datagram is authenticated and deliberately non-mutating: a forged
    /// datagram with a huge counter would otherwise drag the window forward and reject every
    /// genuine packet behind it, which is a denial of service available to anyone who can
    /// reach the socket.
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

    /// Forgets everything. A new session's counters start from nothing and say nothing about
    /// the last session's.
    public mutating func reset() {
        highest = 0
        seen = 0
        started = false
    }
}

/// Cuts a video payload into datagrams and seals each one.
///
/// **Why 1024-byte chunks rather than the control channel's 16 KB.** A datagram is not a
/// stream: it is one packet, and a packet larger than the path MTU is fragmented by IP or
/// dropped by the first hop that will not fragment. A 16 KB chunk would be eleven fragments
/// on a 1500-byte path and would lose the whole picture to any one of them being lost, which
/// is the opposite of what a lossy lane wants. At ``VideoChunk/maxDatagramPayload`` a sealed
/// datagram is about 1080 bytes — the chunk, its header, the framing length and kind, the
/// counter and the tag — which stays under the 1280-byte minimum MTU of IPv6 and comfortably
/// under a 1500-byte Ethernet path.
///
/// The chunking itself is ``VideoChunkEncoder``'s, unchanged, so a payload that travels a
/// datagram here and a control message there is cut by the same code and put back together
/// by the same reassembler.
public struct VideoDatagramSealer: Sendable {
    private let key: SymmetricKey
    private let token: Data
    private var counter: UInt64 = 0
    /// Distinguishes the chunks of one payload from the next, exactly as it does on the
    /// control lane.
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
    /// An empty result means the payload could not be sealed or was larger than the chunk
    /// header can count; either way nothing goes on the wire, because half a picture is not
    /// worth sending.
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

    /// The 12 bytes ChaChaPoly wants, built from the 8 the wire carries.
    ///
    /// Four leading zeros and the counter, big-endian. The counter is the whole of the nonce's
    /// entropy, and it never repeats under a key — see ``VideoKeySchedule`` for why the two
    /// directions therefore need two keys.
    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce? {
        var bytes = Data([0, 0, 0, 0])
        bytes.appendBigEndian(counter)
        return try? ChaChaPoly.Nonce(data: bytes)
    }
}

/// Opens sealed datagrams and puts the payloads inside them back together.
///
/// Both halves live here because neither is useful alone: a datagram carries one chunk of one
/// picture, so the only thing a receiver ever wants is the whole frame, and a caller left to
/// feed a reassembler itself would be re-implementing the one rule that matters — that a
/// chunk of a newer picture discards whatever was being assembled for the older one.
///
/// **One of these per lane.** Two lanes carry video at once while the client is in fallback:
/// the datagram lane and the control channel. They interleave on the wire, their chunk
/// numbering is independent, and a single reassembler shared between them would read the
/// other lane's chunks as a newer picture and abandon the one it was assembling — a picture
/// that stutters exactly as often as the probe timer fires.
public struct VideoDatagramOpener {
    private let key: SymmetricKey
    private var window = VideoReplayWindow()
    private var chunks = VideoChunkReassembler()

    public init(key: SymmetricKey) {
        self.key = key
    }

    /// The whole frame this datagram completed, or `nil` when it carried a piece of one or
    /// was one the window refused.
    ///
    /// A `nil` return is the ordinary case rather than a failure: a large picture arrives as
    /// twenty datagrams and only the last of them completes it, and a duplicate or a datagram
    /// older than the window is expected on any real path. Anything that is genuinely wrong
    /// with the datagram throws.
    public mutating func open(_ datagram: Data) throws -> Frame? {
        guard datagram.count >= VideoDatagram.minForwardedSize else {
            throw VideoDatagramError.truncated(have: datagram.count, need: VideoDatagram.minForwardedSize)
        }
        // A datagram is at most a path MTU in this protocol, and one that claims otherwise
        // came from something that is not a peer running it. Refused before any of it is
        // parsed, which is the same rule the frame decoder applies to a declared length.
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

        // Only now, having proved the datagram came from the peer, does it get to move the
        // window — see ``VideoReplayWindow/accepts(_:)``.
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
/// **One class for both ends, because they differ only in which half they use.** The Mac
/// seals and sends; the phone opens and receives; and both have to bind, because the relay
/// will not forward to an address it has not been told about. That is the whole difference,
/// and a second class would be the same socket with the same timer and one fewer callback.
///
/// The bind is not a formality. A NAT binding expires, and a session that stops being
/// forwarded to does not report anything — the picture simply stops, on a link where every
/// other signal says the connection is fine. Repeating the bind on a timer is what keeps that
/// from happening on a call nobody touched for a few minutes.
public final class VideoDatagramSocket: @unchecked Sendable {
    /// How often the bind is repeated.
    ///
    /// Well inside the shortest UDP timeout anyone deploys, and two orders of magnitude
    /// cheaper than the video it is keeping alive: sixteen bytes against a stream measured in
    /// megabits.
    public static let keepaliveInterval: TimeInterval = 10

    /// How many datagrams may be held while the bind is still going out.
    ///
    /// A queue rather than a flag because the alternative is dropping them: sends made before
    /// the bind would reach the relay before it knows the address, and the answer to "we are
    /// not registered yet" is to wait a moment, not to throw the picture away. Bounded, and
    /// the oldest goes first when it is full, which is the same rule the rest of the video
    /// path uses.
    private static let maxHeldDatagrams = 32

    /// Named by the caller, because the two ends run the same code and a stack trace should
    /// say which of them it came from.
    private let queue: DispatchQueue
    private let connection: NWConnection
    private let token: Data

    private var bindTimer: DispatchSourceTimer?
    /// Datagrams waiting for the bind, each with the caller that is waiting for them.
    ///
    /// A list of callers rather than one, because two kinds of send share this socket: the
    /// pump's, which must be told when its frames are away or it never sends another, and a
    /// probe's, which does not care. Keeping only the last caller's completion would drop the
    /// pump's on the floor and stop the picture for the rest of the session.
    private var held: [(datagrams: [Data], completion: (@Sendable (Error?) -> Void)?)] = []
    private var heldCount = 0
    private var bound = false
    private var stopped = false

    /// Set before ``start()``. A datagram that arrived, with the relay's token prefix already
    /// stripped and nothing else done to it.
    public var onDatagram: (@Sendable (Data) -> Void)?
    /// Set before ``start()``. Called for a socket that failed, and on every send that fails.
    public var onFailure: (@Sendable (Error) -> Void)?

    /// Counters for the diagnostics panel. Written on ``queue``, read from anywhere.
    private let counterLock = NSLock()
    private var _sent = 0
    private var _received = 0

    public var sentDatagrams: Int { counterLock.withLock { _sent } }
    public var receivedDatagrams: Int { counterLock.withLock { _received } }

    public init(host: String, port: UInt16, token: Data, label: String) throws {
        guard token.count == VideoDatagram.tokenSize else {
            throw VideoDatagramError.invalidToken(bytes: token.count)
        }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw VideoDatagramError.invalidPort(port)
        }
        self.token = token
        queue = DispatchQueue(label: label)
        connection = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(host), port: endpointPort),
            using: .udp
        )
    }

    /// Opens the socket, binds, and keeps the binding alive until ``cancel()``.
    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendBind()
                self.startBindTimer()
                self.receiveNext()
            case .failed(let error):
                // A socket that has genuinely failed is worth saying out loud. `.waiting` is
                // not: a UDP connection sits there whenever the interface is between states,
                // resolves by itself, and reporting it would offer the user a problem that
                // has already gone away.
                self.onFailure?(error)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Sends the datagrams one payload became, and reports when the last of them is away.
    ///
    /// The completion is what drives the sender's flow control — one item in flight at a
    /// time — so it is called for the whole group rather than per datagram, and a group held
    /// waiting for the bind reports once it has actually been sent.
    public func send(_ datagrams: [Data], completion: @escaping @Sendable (Error?) -> Void) {
        guard !datagrams.isEmpty else {
            completion(nil)
            return
        }
        queue.async { [weak self] in
            guard let self, !self.stopped else {
                completion(nil)
                return
            }
            guard self.bound else {
                // Waiting for the bind. The oldest goes when the queue is full: a picture
                // that is already stale is worth less than the one that just arrived, and a
                // part of a picture is worth less than either.
                self.held.append((datagrams, completion))
                self.heldCount += datagrams.count
                // The newest is always kept, even when it alone is larger than the cap: it is
                // the picture the client has not seen, and the ones being dropped are not.
                while self.heldCount > Self.maxHeldDatagrams, self.held.count > 1 {
                    self.heldCount -= self.held.removeFirst().datagrams.count
                }
                return
            }
            self.write(datagrams, completion: completion)
        }
    }

    public func cancel() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    // MARK: - All on `queue`

    /// Registers this address with the relay and tells it which session the address belongs
    /// to. Sixteen bytes and no payload: everything after the token would be forwarded.
    private func sendBind() {
        connection.send(content: token, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                // The bind is the one send that has to work. Without it the relay has nowhere
                // to forward from, and every send after it would be held waiting for a bind
                // that is not coming — which is not a dropped picture but a pump that never
                // runs again, including after the client gives up on this lane and asks for
                // the control channel instead. So the socket is closed, and the frames that
                // were waiting go the way every datagram on a blocked path goes: nowhere, and
                // without stopping anything.
                self.onFailure?(error)
                self.stopOnQueue()
                return
            }
            self.bound = true
            self.flushHeld()
        })
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
        connection.cancel()
        for entry in waiting { entry.completion?(nil) }
    }

    private func flushHeld() {
        guard !held.isEmpty else { return }
        let waiting = held
        held.removeAll(keepingCapacity: true)
        heldCount = 0

        let datagrams = waiting.flatMap(\.datagrams)
        write(datagrams) { error in
            // Every caller is told together and in order. Each of them asked for a send that
            // is now behind them in the same queue, so "everything up to mine is away" is the
            // same moment for all of them.
            for entry in waiting { entry.completion?(error) }
        }
    }

    private func write(_ datagrams: [Data], completion: (@Sendable (Error?) -> Void)?) {
        var remaining = datagrams
        let last = remaining.removeLast()
        // Every datagram but the last goes out without bookkeeping, for the same reason the
        // control lane's chunks do: only the last one gates the next picture, and a per
        // datagram completion would be a callback storm for no added ordering.
        for datagram in remaining {
            connection.send(content: datagram, completion: .contentProcessed { _ in })
        }
        connection.send(content: last, completion: .contentProcessed { [weak self] error in
            if let self {
                self.counterLock.withLock { self._sent += datagrams.count }
                if let error { self.onFailure?(error) }
            }
            completion?(error)
        })
    }

    private func startBindTimer() {
        guard bindTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.keepaliveInterval,
            repeating: Self.keepaliveInterval,
            leeway: .seconds(1)
        )
        // The bind, not a sealed datagram: it is the address the relay remembers, and the
        // video itself keeps the other direction's mapping warm simply by existing.
        timer.setEventHandler { [weak self] in self?.sendBind() }
        timer.resume()
        bindTimer = timer
    }

    private func receiveNext() {
        // The datagram-preserving read rather than the stream one: what arrives is one
        // datagram and what leaves here is one datagram, which is the whole contract between
        // the sealer and the opener.
        connection.receiveMessage { [weak self] (data: Data?, _: NWConnection.ContentContext?, _: Bool, error: NWError?) in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.counterLock.withLock { self._received += 1 }
                self.onDatagram?(data)
            }
            if let error {
                self.onFailure?(error)
                return
            }
            self.receiveNext()
        }
    }
}
