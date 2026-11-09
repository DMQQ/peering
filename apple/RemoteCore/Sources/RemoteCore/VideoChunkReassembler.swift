import Foundation

/// The rule that makes that safe is the frame identity: a chunk belonging to a newer frame discards
/// whatever was being assembled, so a lost chunk costs one picture and never wedges the stream.
public struct VideoChunkReassembler {
    private var frameID: UInt32?
    private var innerKind: MessageKind?
    private var expected = 0
    private var parts: [Int: Data] = [:]
    /// Parity bodies by group, and the payload length they carry.
    private var parities: [Int: [UInt8]] = [:]
    private var totalLength: Int?
    private var bytes = 0
    /// The frame last handed out. Its trailing parity chunks are still on the wire and would each open an empty assembly.
    private var completedFrameID: UInt32?

    /// A parameter rather than the constant because there are two answers: for a picture the video
    /// figure exists only to stop a peer claiming 65535 chunks, while a clipboard payload's largest
    /// legitimate thing is a photograph, in megabytes, which that guard would refuse. See
    /// ``ClipboardLimits``. The default is the video figure.
    private let maxReassembled: Int

    public init(maxReassembled: Int = VideoChunk.maxReassembledPayload) {
        self.maxReassembled = maxReassembled
    }

    public mutating func ingest(_ frame: Frame) throws -> Frame? {
        let header = try ChunkHeader(frame.payload)
        if header.frameID == completedFrameID { return nil }
        if frameID != header.frameID {
            clear()
            frameID = header.frameID
            innerKind = header.inner
            expected = header.count
        }
        // A chunk that contradicts the frame it claims to belong to is not from this frame.
        // Ignoring it costs this frame; acting on it would corrupt the one being assembled.
        guard header.inner == innerKind, header.count == expected else { return nil }

        let group: Int
        if header.index >= header.count {
            group = header.index - header.count
            keepParity(group: group, body: header.body)
        } else {
            group = header.index / VideoChunk.parityGroupSize
            if parts[header.index] == nil {
                parts[header.index] = header.body
                bytes += header.body.count
            }
        }
        if bytes > maxReassembled {
            clear()
            return nil
        }
        if parts.count != expected { recover(group: group) }
        guard parts.count == expected else { return nil }

        var assembled = Data(capacity: bytes)
        for index in 0..<expected {
            guard let part = parts[index] else { return nil }
            assembled.append(part)
        }
        let kind = header.inner
        completedFrameID = frameID
        clear()
        return Frame(kind: kind, payload: assembled)
    }

    private mutating func keepParity(group: Int, body: Data) {
        guard body.count > VideoChunk.parityLengthSize else { return }
        let base = body.startIndex
        totalLength = Int(body.readBigEndianUInt32(at: base))
        parities[group] = [UInt8](body[(base + VideoChunk.parityLengthSize)...])
    }

    /// Rebuilds the one missing chunk of `group` once its parity has arrived, which is the only group the chunk just ingested can have changed. Two missing in a group cannot be told apart, so that group is left, and the picture is lost as it was before parity existed.
    private mutating func recover(group: Int) {
        guard let total = totalLength, let xor = parities[group] else { return }
        let first = group * VideoChunk.parityGroupSize
        let members = first..<min(first + VideoChunk.parityGroupSize, expected)
        var lost: Int?
        for index in members where parts[index] == nil {
            if lost != nil { return }
            lost = index
        }
        guard let lost else { return }
        var rebuilt = xor
        for present in members where present != lost {
            guard let part = parts[present] else { continue }
            part.withUnsafeBytes { source in
                for offset in 0..<min(source.count, rebuilt.count) { rebuilt[offset] ^= source[offset] }
            }
        }
        let length = lost == expected - 1 ? total - (expected - 1) * xor.count : xor.count
        guard length >= 0, length <= rebuilt.count else { return }
        let chunk = Data(rebuilt.prefix(length))
        parts[lost] = chunk
        bytes += chunk.count
    }

    private mutating func clear() {
        frameID = nil
        innerKind = nil
        expected = 0
        parts.removeAll(keepingCapacity: true)
        parities.removeAll(keepingCapacity: true)
        totalLength = nil
        bytes = 0
    }
}

/// What a chunk's first bytes say about where it belongs, with the body behind them.
private struct ChunkHeader {
    let inner: MessageKind
    let frameID: UInt32
    let index: Int
    let count: Int
    let body: Data

    init(_ payload: Data) throws {
        guard payload.count >= VideoChunk.headerSize else {
            throw VideoChunkError.truncatedHeader(have: payload.count, need: VideoChunk.headerSize)
        }
        // `payload` is a slice of the decoder's buffer, so it does not start at zero.
        let base = payload.startIndex
        guard let kind = MessageKind(rawValue: payload[base]), kind != .videoChunk else {
            throw VideoChunkError.nestedChunk
        }
        let count = Int(payload.readBigEndianUInt16(at: base + 7))
        let index = Int(payload.readBigEndianUInt16(at: base + 5))
        let parityGroups = (count + VideoChunk.parityGroupSize - 1) / VideoChunk.parityGroupSize
        guard count > 0, index < count + parityGroups else {
            throw VideoChunkError.chunkOutOfRange(index: index, count: count)
        }
        let body = Data(payload[(base + VideoChunk.headerSize)...])
        guard body.count <= VideoChunk.maxPayload else {
            throw VideoChunkError.oversizedChunk(bytes: body.count)
        }
        self.inner = kind
        self.frameID = payload.readBigEndianUInt32(at: base + 1)
        self.index = index
        self.count = count
        self.body = body
    }
}
