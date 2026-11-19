import Foundation
import Testing

@testable import RemoteCore

struct ChunkReassemblersTests {
    private let picture = Data((0..<40).map { UInt8($0) })
    private let sound = Data((100..<130).map { UInt8($0) })

    private func chunks(of payload: Data, kind: MessageKind, frameID: UInt32) -> [Frame] {
        VideoChunkEncoder.encode(kind: kind, payload: payload, frameID: frameID, chunkSize: 8)
    }

    @Test func aSoundFrameInTheMiddleOfAPictureCostsNeitherOfThem() throws {
        let video = chunks(of: picture, kind: .videoFrame, frameID: 1)
        let audio = chunks(of: sound, kind: .audioFrame, frameID: 2)
        var reassemblers = ChunkReassemblers()
        var delivered: [Frame] = []

        // Two picture chunks, then the whole sound frame, then the rest of the picture.
        for frame in video.prefix(2) + audio + video.dropFirst(2) {
            if let done = try reassemblers.ingest(frame) { delivered.append(done) }
        }

        #expect(delivered.map(\.kind) == [.audioFrame, .videoFrame])
        #expect(delivered.first { $0.kind == .videoFrame }?.payload == picture)
        #expect(delivered.first { $0.kind == .audioFrame }?.payload == sound)
    }

    @Test func aSingleReassemblerLosesThePictureToTheSameInterleaving() throws {
        let video = chunks(of: picture, kind: .videoFrame, frameID: 1)
        let audio = chunks(of: sound, kind: .audioFrame, frameID: 2)
        var reassembler = VideoChunkReassembler()
        var delivered: [Frame] = []

        for frame in video.prefix(2) + audio + video.dropFirst(2) {
            if let done = try reassembler.ingest(frame) { delivered.append(done) }
        }

        #expect(!delivered.contains { $0.kind == .videoFrame })
    }

    @Test func aNewerPictureStillReplacesAnUnfinishedOne() throws {
        let first = chunks(of: picture, kind: .videoFrame, frameID: 1)
        let second = chunks(of: picture, kind: .videoFrame, frameID: 2)
        var reassemblers = ChunkReassemblers()
        var delivered: [Frame] = []

        for frame in first.prefix(2) + second {
            if let done = try reassemblers.ingest(frame) { delivered.append(done) }
        }

        #expect(delivered.count == 1)
        #expect(delivered.first?.payload == picture)
    }
}

struct AudioPauseWireTests {
    @Test func theCommandSurvivesTheCodec() throws {
        let data = try MessageCodec.encode(RemoteCommand.setAudioEnabled(false))
        #expect(try MessageCodec.decode(RemoteCommand.self, from: data) == .setAudioEnabled(false))
    }
}
