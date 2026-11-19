import Foundation

/// One ``VideoChunkReassembler`` per kind of message, so chunks of different kinds can interleave on a lane.
///
/// A single reassembler treats a chunk of a newer frame as the end of the frame it was building, which is right for pictures and wrong for anything sharing the lane: an audio frame arriving mid-picture would cost the picture. The kind is already in every chunk header, so receiving this way needs nothing new on the wire. Chunks of one kind are still assembled one frame at a time.
public struct ChunkReassemblers {
    private var byKind: [MessageKind: VideoChunkReassembler] = [:]

    public init() {}

    public mutating func ingest(_ frame: Frame) throws -> Frame? {
        // A header too short to name its kind goes to a reassembler of its own, which refuses it with the usual error.
        let kind = VideoChunk.innerKind(of: frame) ?? .videoChunk
        var reassembler = byKind[kind] ?? VideoChunkReassembler()
        defer { byKind[kind] = reassembler }
        return try reassembler.ingest(frame)
    }
}
