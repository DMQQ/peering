import Foundation

/// The rates either end may ask for, defined once.
///
/// Both ends act on the same numbers: the client picks a tier from its own measurements and the
/// host applies the control-channel ceiling on top. A rate defined twice is a session whose two
/// ends disagree about what the link is carrying.
public enum VideoQualityTier: Int, Sendable, CaseIterable {
    case low = 2_000
    case medium = 8_000
    case high = 20_000
}

public enum VideoTransport: String, Codable, Sendable, Equatable, CaseIterable {
    /// The transport the session would rather use: the video connection, and the relay's
    /// video datagrams behind it. Its own path, at full quality.
    case primary
    /// The authenticated control channel, at reduced quality.
    ///
    /// Video here shares the link that carries input and the catalogue, which is worth the price
    /// only when the alternative is no picture at all, which is why the rate is capped. See
    /// ``VideoFallbackPolicy/controlChannelBitrateKbps``.
    case control
}

/// A client's request that the host move video between the two transports.
///
/// The client decides, because the host cannot see whether its datagrams arrive: nothing
/// acknowledges them, and a send into a network that drops it looks like a send that worked.
public struct VideoTransportRequest: Codable, Sendable, Equatable {
    public let transport: VideoTransport
    /// What the client observed, for the host's log. Diagnostics, not protocol: the host acts
    /// on the transport named above and never on this sentence.
    public let reason: String

    public init(transport: VideoTransport, reason: String) {
        self.transport = transport
        self.reason = reason
    }
}

public enum VideoChunkError: Error, Equatable, Sendable {
    /// The payload ended before the fixed header did.
    case truncatedHeader(have: Int, need: Int)
    /// The header declared a chunk index outside the count it also declared.
    case chunkOutOfRange(index: Int, count: Int)
    /// A chunk of a chunk. Nothing nests here, and accepting one would let a peer build
    /// unbounded work out of a single frame.
    case nestedChunk
    /// One chunk carried more than ``VideoChunk/maxPayload`` bytes.
    case oversizedChunk(bytes: Int)
}

/// One piece of a video-channel payload, when that payload is travelling the control channel.
///
/// The payload is the same one the video transport carries: ``EncodedVideoFrame/encoded()`` bytes,
/// a ``VideoStreamConfig``'s JSON, or an audio frame.
///
/// Cut up because a control channel message is capped at ``ProtocolInfo/maxControlPayload``, a cap
/// the receiving end enforces: an oversized message is not refused by the end that produced it, it
/// goes out and arrives as megabytes on the phone. Chunking also lets the host write one piece at a
/// time, so a pong goes out between two of them.
public enum VideoChunk {
    /// innerKind(1) + frameID(4) + index(2) + count(2)
    public static let headerSize = 9

    /// The most payload one chunk may carry.
    ///
    /// A quarter of the inbound control cap, so a chunk's whole frame has a four-fold margin under
    /// it. At the control channel's capped rate a chunk is about 60 ms of wire time, which bounds
    /// what an interleaved control message can wait for.
    public static let maxPayload = 16 * 1024

    /// The most payload one chunk may carry when the payload is travelling a datagram.
    ///
    /// A datagram is bounded by the path's MTU, because a larger one is fragmented and a picture
    /// loses everything to any one fragment being dropped. At this size a sealed datagram is around
    /// 1080 bytes with its header, counter, tag and the relay's token, inside IPv6's 1280.
    ///
    /// The reassembler's ceiling stays at ``maxPayload``: it accepts chunks from both lanes.
    public static let maxDatagramPayload = 1024

    /// The most that will be reassembled for one frame, a memory guard rather than a protocol
    /// limit.
    ///
    /// Far above any real picture; what it stops is a peer claiming 65535 chunks and having them
    /// buffered.
    public static let maxReassembledPayload = 4 * 1024 * 1024

    /// The kind of frame a chunk belongs to, or `nil` for a payload too short to hold one.
    ///
    /// The two lanes that use these frames share a connection, so the picture's chunks and the
    /// clipboard's are told apart only by the byte inside. Asked before the reassembler, which
    /// would otherwise spend a whole payload finding out.
    public static func innerKind(of frame: Frame) -> MessageKind? {
        let payload = frame.payload
        guard payload.count >= headerSize else { return nil }
        return MessageKind(rawValue: payload[payload.startIndex])
    }
}

public enum VideoChunkEncoder {
    /// The frames one video-channel payload becomes on the control channel.
    ///
    /// A payload that already fits travels as itself, under its own kind, so a delta frame, an
    /// audio frame or a stream config stays readable in a log. Only what would be too large for a
    /// control message is split.
    public static func encode(
        kind: MessageKind,
        payload: Data,
        frameID: UInt32,
        chunkSize: Int = VideoChunk.maxPayload
    ) -> [Frame] {
        let size = max(1, chunkSize)
        guard payload.count > size else { return [Frame(kind: kind, payload: payload)] }

        let count = (payload.count + size - 1) / size
        // A payload needing more chunks than the header can count is not a picture, and there is no
        // degraded version of it worth sending.
        guard count <= Int(UInt16.max) else { return [] }

        var frames: [Frame] = []
        frames.reserveCapacity(count)
        var offset = payload.startIndex
        for index in 0..<count {
            let end = payload.index(offset, offsetBy: min(size, payload.endIndex - offset))
            var body = Data(capacity: VideoChunk.headerSize + size)
            body.append(kind.rawValue)
            body.appendBigEndian(frameID)
            body.appendBigEndian(UInt16(index))
            body.appendBigEndian(UInt16(count))
            body.append(payload[offset..<end])
            frames.append(Frame(kind: .videoChunk, payload: body))
            offset = end
        }
        return frames
    }
}

/// Puts a chunked payload back together, and drops what it cannot.
///
/// Chunks are lost as a matter of course: a session is not one connection, and a chunk can be
/// abandoned when the host tears a stream down mid-frame, so the client must never be left holding
/// half a picture waiting for a piece that is not coming.
///
/// The rule that makes that safe is the frame identity: a chunk belonging to a newer frame discards
/// whatever was being assembled, so a lost chunk costs one picture and never wedges the stream.
public struct VideoChunkReassembler {
    private var frameID: UInt32?
    private var innerKind: MessageKind?
    private var expected = 0
    private var parts: [Int: Data] = [:]
    private var bytes = 0

    /// The most that will be buffered for one frame.
    ///
    /// A parameter rather than the constant because there are two answers: for a picture the video
    /// figure exists only to stop a peer claiming 65535 chunks, while a clipboard payload's largest
    /// legitimate thing is a photograph, in megabytes, which that guard would refuse. See
    /// ``ClipboardLimits``. The default is the video figure.
    private let maxReassembled: Int

    public init(maxReassembled: Int = VideoChunk.maxReassembledPayload) {
        self.maxReassembled = maxReassembled
    }

    /// - Returns: the whole frame, once every chunk of it has arrived.
    /// - Throws: ``VideoChunkError`` for a frame that is malformed rather than merely early. The
    ///   caller drops it: video is droppable and the next frame starts clean.
    public mutating func ingest(_ frame: Frame) throws -> Frame? {
        let payload = frame.payload
        guard payload.count >= VideoChunk.headerSize else {
            throw VideoChunkError.truncatedHeader(have: payload.count, need: VideoChunk.headerSize)
        }

        // `payload` is a slice of the decoder's buffer, so it does not start at zero.
        let base = payload.startIndex
        let innerRaw = payload[base]
        guard let inner = MessageKind(rawValue: innerRaw), inner != .videoChunk else {
            throw VideoChunkError.nestedChunk
        }
        let frameID = payload.readBigEndianUInt32(at: base + 1)
        let index = Int(payload.readBigEndianUInt16(at: base + 5))
        let count = Int(payload.readBigEndianUInt16(at: base + 7))
        guard count > 0, index < count else {
            throw VideoChunkError.chunkOutOfRange(index: index, count: count)
        }

        let body = Data(payload[(base + VideoChunk.headerSize)...])
        guard body.count <= VideoChunk.maxPayload else {
            throw VideoChunkError.oversizedChunk(bytes: body.count)
        }

        if self.frameID != frameID {
            self.frameID = frameID
            innerKind = inner
            expected = count
            parts.removeAll(keepingCapacity: true)
            bytes = 0
        }
        // A chunk that contradicts the frame it claims to belong to is not from this frame.
        // Ignoring it costs this frame; acting on it would corrupt the one being assembled.
        guard inner == innerKind, count == expected else { return nil }

        if parts[index] == nil {
            parts[index] = body
            bytes += body.count
        }
        guard bytes <= maxReassembled, parts.count == expected else {
            if bytes > maxReassembled { clear() }
            return nil
        }

        var assembled = Data(capacity: bytes)
        for index in 0..<expected {
            guard let part = parts[index] else { return nil }
            assembled.append(part)
        }
        let kind = inner
        clear()
        return Frame(kind: kind, payload: assembled)
    }

    private mutating func clear() {
        frameID = nil
        innerKind = nil
        expected = 0
        parts.removeAll(keepingCapacity: true)
        bytes = 0
    }
}

/// When the client decides the video transport is not working, and when it decides it is again.
///
/// Pure state and pure arithmetic over values the caller supplies, so the rules can be read and
/// tested without a network.
///
/// Not a measure of the link: nothing here times packets, measures throughput or counts losses. The
/// question is only "is a picture arriving", the only one answerable from the client's side.
public struct VideoFallbackPolicy: Sendable {
    public enum Decision: Sendable, Equatable, CaseIterable {
        /// Nothing to say. Either the picture is arriving, the control channel is not in a
        /// state to be trusted with it, or this session's path cannot block video.
        case none
        /// Ask the host to put video on the control channel.
        case useControlChannel
        /// Ask the host to put video back on the transport it prefers.
        case usePrimaryTransport
    }

    /// How long a session may go without a picture before the transport is treated as broken.
    ///
    /// Measured from the moment the session became ready, so the first three seconds are a probe:
    /// nothing extra is sent to ask whether the path works.
    public static let silenceBeforeFallback: TimeInterval = 3

    /// What "the control channel is healthy" means: it answered something within this long.
    ///
    /// The client pings once a second, so a pong inside five seconds is four missed round trips.
    /// Moving video onto a channel that is itself failing would take the picture off the one lane
    /// still working.
    public static let controlHealthWindow: TimeInterval = 5

    /// How often the client re-asks while the condition that prompted the request persists.
    ///
    /// Also the cooling-off period after a return to the preferred transport, so a lane just given
    /// a second chance gets these seconds to prove itself.
    public static let requestRepeatInterval: TimeInterval = 5

    /// How long the fallback must hold before the client will consider leaving it.
    public static let minFallbackHold: TimeInterval = 5

    /// How many pictures must arrive on the preferred transport before it is believed again.
    ///
    /// Two, not one: the host probes that transport with keyframes while video is on the control
    /// channel, and a single datagram does get through on a path otherwise losing everything.
    public static let primaryPicturesForReturn = 2

    /// What the control channel is allowed to carry while video is on it.
    ///
    /// The `low` tier: the host applies it as a ceiling and the client stops asking for more while
    /// it is in force, which is what makes a capped session read as deliberately reduced rather
    /// than broken.
    public static let controlChannelBitrateKbps = VideoQualityTier.low.rawValue

    /// What the picture goes back to when the client has never said what it wants.
    ///
    /// The client sends its tier the moment a session is ready, so reaching this means the command
    /// was lost rather than that nobody spoke.
    public static let preferredTransportBitrateKbps = VideoQualityTier.high.rawValue

    /// Whether video is currently being taken off the preferred transport.
    public private(set) var isFallback = false

    private var lastRequestAt: TimeInterval?
    private var fellBackAt: TimeInterval = 0
    private var primaryPictures = 0

    public init() {}

    /// - Parameters:
    ///   - now: monotonic seconds, not a wall clock: a device syncing its time must not trip it.
    ///   - lastPictureAt: when a picture last arrived, on either transport. The caller sets it to
    ///     the moment the session became ready, so the first few seconds are the probe above.
    ///   - lastControlReplyAt: when the control channel last answered. `nil` before it has.
    ///   - applies: whether this session's video could travel a path a network can block at all.
    ///     False on the local network, where a missing picture is a different problem.
    public mutating func advance(
        now: TimeInterval,
        lastPictureAt: TimeInterval?,
        lastControlReplyAt: TimeInterval?,
        applies: Bool
    ) -> Decision {
        guard applies else { return .none }

        if isFallback {
            if now - fellBackAt >= Self.minFallbackHold,
               primaryPictures >= Self.primaryPicturesForReturn {
                isFallback = false
                primaryPictures = 0
                lastRequestAt = now
                return .usePrimaryTransport
            }

            // The host is entitled to decline a request: a Mac producing nothing cannot tell a
            // blocked path from a still screen either. A request that produced no picture is
            // therefore repeated rather than assumed to have worked.
            let askedAt = lastRequestAt ?? 0
            // Nothing has arrived since the request itself, so the picture is no better for having
            // asked; anything that did arrive is for the conditions above to judge.
            let picturedSinceAsking = lastPictureAt.map { $0 > askedAt } ?? false
            if !picturedSinceAsking, now - askedAt >= Self.requestRepeatInterval {
                lastRequestAt = now
                return .useControlChannel
            }
            return .none
        }

        guard let lastPictureAt, now - lastPictureAt >= Self.silenceBeforeFallback else { return .none }
        // The control channel has to be demonstrably alive: it is about to carry the session's
        // whole picture, and a lane failing on its own would turn one broken direction into two.
        guard let lastReply = lastControlReplyAt, now - lastReply <= Self.controlHealthWindow else {
            return .none
        }
        if let lastRequestAt, now - lastRequestAt < Self.requestRepeatInterval { return .none }

        lastRequestAt = now
        fellBackAt = now
        primaryPictures = 0
        isFallback = true
        return .useControlChannel
    }

    /// One picture arrived on the transport the session prefers, counted only while the fallback is
    /// in force: pictures arriving on a transport video is already on are the ordinary case.
    public mutating func notePrimaryPicture() {
        guard isFallback else { return }
        primaryPictures += 1
    }

    /// Forgets everything. A new session has no history, and evidence from the last one describes a
    /// link that no longer exists.
    public mutating func reset() {
        isFallback = false
        lastRequestAt = nil
        fellBackAt = 0
        primaryPictures = 0
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    func readBigEndianUInt16(at index: Index) -> UInt16 {
        var value: UInt16 = 0
        for offset in 0..<2 {
            value = (value << 8) | UInt16(self[index + offset])
        }
        return value
    }
}
