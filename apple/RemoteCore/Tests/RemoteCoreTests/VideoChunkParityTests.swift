import Foundation
import Testing

@testable import RemoteCore

struct VideoChunkParityTests {
    /// Eleven chunks of two bytes, the last holding one, so the first group is full and the second is the short last chunk alone.
    private func elevenChunks() -> (payload: Data, frames: [Frame]) {
        let payload = Data((0..<21).map { UInt8($0) })
        let frames = VideoChunkEncoder.encodeWithParity(kind: .videoFrame, payload: payload, frameID: 7, chunkSize: 2)
        return (payload, frames)
    }

    private func feed(_ frames: [Frame]) throws -> Frame? {
        var reassembler = VideoChunkReassembler()
        var done: Frame?
        for frame in frames { done = try reassembler.ingest(frame) ?? done }
        return done
    }

    @Test func parityBodiesAreTheLengthThenTheXorOfTheGroup() {
        let payload = Data((0..<10).map { UInt8($0) })
        let frames = VideoChunkEncoder.encodeWithParity(kind: .videoFrame, payload: payload, frameID: 7, chunkSize: 4, group: 2)
        let kind = MessageKind.videoFrame.rawValue
        #expect(frames.count == 5)
        #expect(Array(frames[3].payload) == [kind, 0, 0, 0, 7, 0, 3, 0, 3, 0, 0, 0, 10, 4, 4, 4, 4])
        #expect(Array(frames[4].payload) == [kind, 0, 0, 0, 7, 0, 4, 0, 3, 0, 0, 0, 10, 8, 9, 0, 0])
    }

    @Test func anySingleLostChunkIsRebuiltFromItsGroupsParity() throws {
        let (payload, frames) = elevenChunks()
        #expect(frames.count == 13)
        for lost in 0..<11 {
            let kept = frames.enumerated().filter { $0.offset != lost }.map(\.element)
            #expect(try feed(kept)?.payload == payload, "lost chunk \(lost)")
        }
    }

    @Test func parityArrivingFirstStillRebuilds() throws {
        let (payload, frames) = elevenChunks()
        let order = [frames[11], frames[12]] + frames[..<11].enumerated().filter { $0.offset != 4 }.map(\.element)
        #expect(try feed(order)?.payload == payload)
    }

    @Test func parityBodiesCountTowardTheReassemblyLimit() throws {
        let (payload, frames) = elevenChunks()
        let parityFirst = [frames[11], frames[12]] + frames[..<11]
        var tight = VideoChunkReassembler(maxReassembled: payload.count + 1)
        var tightResult: Frame?
        for frame in parityFirst { tightResult = try tight.ingest(frame) ?? tightResult }
        #expect(tightResult == nil)

        var roomy = VideoChunkReassembler(maxReassembled: payload.count + 16)
        var roomyResult: Frame?
        for frame in parityFirst { roomyResult = try roomy.ingest(frame) ?? roomyResult }
        #expect(roomyResult?.payload == payload)
    }

    @Test func twoLostChunksInOneGroupAreNotRebuilt() throws {
        let (_, frames) = elevenChunks()
        let kept = frames.enumerated().filter { $0.offset != 2 && $0.offset != 5 }.map(\.element)
        #expect(try feed(kept) == nil)
    }

    @Test func aWholeFrameIgnoresItsParity() throws {
        let (payload, frames) = elevenChunks()
        #expect(try feed(frames)?.payload == payload)
    }

    @Test func aPayloadThatFitsOnePieceCarriesNoParity() {
        let frames = VideoChunkEncoder.encodeWithParity(kind: .ping, payload: Data([1, 2, 3]), frameID: 1, chunkSize: 1024)
        #expect(frames.count == 1)
    }

    @Test func aRealisticFrameSurvivesOneLossPerGroup() throws {
        let payload = Data((0..<25_000).map { UInt8(truncatingIfNeeded: $0 &* 31 % 251) })
        let size = VideoChunk.maxDatagramPayload
        let frames = VideoChunkEncoder.encodeWithParity(kind: .videoFrame, payload: payload, frameID: 9, chunkSize: size)
        let count = (payload.count + size - 1) / size
        #expect(frames.count == count + (count + VideoChunk.parityGroupSize - 1) / VideoChunk.parityGroupSize)
        let kept = frames.enumerated().filter { $0.offset % VideoChunk.parityGroupSize != 3 || $0.offset >= count }.map(\.element)
        #expect(try feed(kept)?.payload == payload)
    }

    @Test func anIndexBeyondTheDataAndItsParityIsRefused() {
        var reassembler = VideoChunkReassembler()
        var body = Data([MessageKind.videoFrame.rawValue, 0, 0, 0, 1, 0, 6, 0, 5])
        body.append(0)
        #expect(throws: VideoChunkError.self) { try reassembler.ingest(Frame(kind: .videoChunk, payload: body)) }
    }

    @Test func aCompletedFramesTrailingParityIsIgnored() throws {
        let (payload, frames) = elevenChunks()
        var reassembler = VideoChunkReassembler()
        var done: Frame?
        for frame in frames { done = try reassembler.ingest(frame) ?? done }
        #expect(done?.payload == payload)
        // Delivered again, the parity must not restart the frame.
        #expect(try reassembler.ingest(frames[11]) == nil)
        #expect(try reassembler.ingest(frames[12]) == nil)
    }

    @Test func aLateParityOfACompletedFrameDoesNotWipeTheNextFramesProgress() throws {
        let (_, old) = elevenChunks()
        let payload = Data((0..<21).map { UInt8($0) })
        let newer = VideoChunkEncoder.encodeWithParity(kind: .videoFrame, payload: payload, frameID: 8, chunkSize: 2)
        var reassembler = VideoChunkReassembler()
        for frame in old[..<11] { _ = try reassembler.ingest(frame) }
        for frame in newer[..<10] { _ = try reassembler.ingest(frame) }
        _ = try reassembler.ingest(old[11])
        var done: Frame?
        for frame in newer[10...] { done = try reassembler.ingest(frame) ?? done }
        #expect(done?.payload == payload)
    }

    @Test func anOversizedDataChunkNeverBreaksRecovery() throws {
        let (_, frames) = elevenChunks()
        var reassembler = VideoChunkReassembler()
        var fat = frames[3].payload
        fat.append(contentsOf: [UInt8](repeating: 9, count: 40))
        _ = try reassembler.ingest(frames[0])
        _ = try reassembler.ingest(Frame(kind: frames[3].kind, payload: fat))
        _ = try reassembler.ingest(frames[11])
        for frame in frames[4..<10] { _ = try reassembler.ingest(frame) }
    }
}
