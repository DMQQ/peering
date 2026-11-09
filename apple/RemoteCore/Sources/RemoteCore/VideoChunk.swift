import Foundation

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

    /// Data chunks covered by one parity chunk on the datagram lane: one lost chunk in ten is rebuilt, for ten percent more bytes.
    public static let parityGroupSize = 10

    /// Bytes at the front of a parity body that carry the whole payload's length, which the last chunk's length cannot be read from.
    static let parityLengthSize = 4

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

extension VideoChunkEncoder {
    /// Like ``encode(kind:payload:frameID:chunkSize:)``, then one parity chunk per `group` data chunks, numbered after the data ones. A parity body is the payload's length followed by the XOR of its group's chunk bodies, each zero padded to `chunkSize`. A payload that fits one piece goes out as itself and is not protected.
    public static func encodeWithParity(
        kind: MessageKind,
        payload: Data,
        frameID: UInt32,
        chunkSize: Int,
        group: Int = VideoChunk.parityGroupSize
    ) -> [Frame] {
        var frames = encode(kind: kind, payload: payload, frameID: frameID, chunkSize: chunkSize)
        let size = max(1, chunkSize)
        let group = max(1, group)
        guard payload.count > size, !frames.isEmpty else { return frames }
        let count = frames.count
        let groups = (count + group - 1) / group
        guard count + groups <= Int(UInt16.max) else { return frames }

        let bytes = [UInt8](payload)
        for g in 0..<groups {
            var xor = [UInt8](repeating: 0, count: size)
            for index in (g * group)..<min((g + 1) * group, count) {
                let start = index * size
                for offset in 0..<min(size, bytes.count - start) { xor[offset] ^= bytes[start + offset] }
            }
            var body = Data(capacity: VideoChunk.headerSize + VideoChunk.parityLengthSize + size)
            body.append(kind.rawValue)
            body.appendBigEndian(frameID)
            body.appendBigEndian(UInt16(count + g))
            body.appendBigEndian(UInt16(count))
            body.appendBigEndian(UInt32(bytes.count))
            body.append(contentsOf: xor)
            frames.append(Frame(kind: .videoChunk, payload: body))
        }
        return frames
    }
}
