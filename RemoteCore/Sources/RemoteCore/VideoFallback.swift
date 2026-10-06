import Foundation

public enum VideoQualityTier: Int, Sendable, CaseIterable {
    case low = 2_000
    case medium = 8_000
    case high = 20_000
}

public enum VideoTransport: String, Codable, Sendable, Equatable, CaseIterable {
    case primary
    /// Video here shares the link that carries input and the catalogue, which is worth the price
    /// only when the alternative is no picture at all, which is why the rate is capped. See
    case control
}

/// The client decides, because the host cannot see whether its datagrams arrive: nothing
/// acknowledges them, and a send into a network that drops it looks like a send that worked.
public struct VideoTransportRequest: Codable, Sendable, Equatable {
    public let transport: VideoTransport
    public let reason: String

    public init(transport: VideoTransport, reason: String) {
        self.transport = transport
        self.reason = reason
    }
}

public enum VideoChunkError: Error, Equatable, Sendable {
    case truncatedHeader(have: Int, need: Int)
    case chunkOutOfRange(index: Int, count: Int)
    /// A chunk of a chunk. Nothing nests here, and accepting one would let a peer build
    /// unbounded work out of a single frame.
    case nestedChunk
    case oversizedChunk(bytes: Int)
}

/// Cut up because a control channel message is capped at ``ProtocolInfo/maxControlPayload``, a cap
/// the receiving end enforces: an oversized message is not refused by the end that produced it, it
/// goes out and arrives as megabytes on the phone. Chunking also lets the host write one piece at a
/// time, so a pong goes out between two of them.
public enum VideoChunk {
    /// innerKind(1) + frameID(4) + index(2) + count(2)
    public static let headerSize = 9

    public static let maxPayload = 16 * 1024

    /// A datagram is bounded by the path's MTU, because a larger one is fragmented and a picture
    /// loses everything to any one fragment being dropped. At this size a sealed datagram is around
    /// 1080 bytes with its header, counter, tag and the relay's token, inside IPv6's 1280.
    public static let maxDatagramPayload = 1024

    /// Far above any real picture; what it stops is a peer claiming 65535 chunks and having them
    /// buffered.
    public static let maxReassembledPayload = 4 * 1024 * 1024

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

/// The rule that makes that safe is the frame identity: a chunk belonging to a newer frame discards
/// whatever was being assembled, so a lost chunk costs one picture and never wedges the stream.
public struct VideoChunkReassembler {
    private var frameID: UInt32?
    private var innerKind: MessageKind?
    private var expected = 0
    private var parts: [Int: Data] = [:]
    private var bytes = 0

    /// A parameter rather than the constant because there are two answers: for a picture the video
    /// figure exists only to stop a peer claiming 65535 chunks, while a clipboard payload's largest
    /// legitimate thing is a photograph, in megabytes, which that guard would refuse. See
    /// ``ClipboardLimits``. The default is the video figure.
    private let maxReassembled: Int

    public init(maxReassembled: Int = VideoChunk.maxReassembledPayload) {
        self.maxReassembled = maxReassembled
    }

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

/// Not a measure of the link: nothing here times packets, measures throughput or counts losses. The
/// question is only "is a picture arriving", the only one answerable from the client's side.
public struct VideoFallbackPolicy: Sendable {
    public enum Decision: Sendable, Equatable, CaseIterable {
        case none
        case useControlChannel
        case usePrimaryTransport
    }

    /// Measured from the moment the session became ready, so the first three seconds are a probe:
    /// nothing extra is sent to ask whether the path works.
    public static let silenceBeforeFallback: TimeInterval = 3

    /// The client pings once a second, so a pong inside five seconds is four missed round trips.
    /// Moving video onto a channel that is itself failing would take the picture off the one lane
    /// still working.
    public static let controlHealthWindow: TimeInterval = 5

    /// Also the cooling-off period after a return to the preferred transport, so a lane just given
    /// a second chance gets these seconds to prove itself.
    public static let requestRepeatInterval: TimeInterval = 5

    public static let minFallbackHold: TimeInterval = 5

    /// Two, not one: the host probes that transport with keyframes while video is on the control
    /// channel, and a single datagram does get through on a path otherwise losing everything.
    public static let primaryPicturesForReturn = 2

    /// The `low` tier: the host applies it as a ceiling and the client stops asking for more while
    /// it is in force, which is what makes a capped session read as deliberately reduced rather
    /// than broken.
    public static let controlChannelBitrateKbps = VideoQualityTier.low.rawValue

    /// The client sends its tier the moment a session is ready, so reaching this means the command
    /// was lost rather than that nobody spoke.
    public static let preferredTransportBitrateKbps = VideoQualityTier.high.rawValue

    public private(set) var isFallback = false

    private var lastRequestAt: TimeInterval?
    private var fellBackAt: TimeInterval = 0
    private var primaryPictures = 0

    public init() {}

    /// `now` is monotonic seconds, not a wall clock: a device syncing its time must not trip it.
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

    public mutating func notePrimaryPicture() {
        guard isFallback else { return }
        primaryPictures += 1
    }

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
