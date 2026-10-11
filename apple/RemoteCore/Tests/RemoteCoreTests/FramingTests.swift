import Foundation
import Testing

@testable import RemoteCore

@Suite("Framing")
struct FramingTests {
    private func drain(_ decoder: inout FrameDecoder) throws -> [Frame] {
        var frames: [Frame] = []
        while let frame = try decoder.next() { frames.append(frame) }
        return frames
    }

    @Test("round-trips a single frame")
    func roundTrip() throws {
        let original = Frame(kind: .command, payload: Data("hello".utf8))
        var decoder = FrameDecoder()
        decoder.append(FrameEncoder.encode(original))
        #expect(try drain(&decoder) == [original])
    }

    @Test("round-trips a frame with an empty payload")
    func emptyPayload() throws {
        let original = Frame(kind: .ping)
        var decoder = FrameDecoder()
        decoder.append(FrameEncoder.encode(original))
        let frames = try drain(&decoder)
        #expect(frames.count == 1)
        #expect(frames[0].kind == .ping)
        #expect(frames[0].payload.isEmpty)
    }

    @Test("encodes the length big-endian, counting the kind byte")
    func encodingIsBigEndian() {
        let encoded = FrameEncoder.encode(kind: .ping)
        #expect(Array(encoded) == [0x00, 0x00, 0x00, 0x01, MessageKind.ping.rawValue])
    }

    @Test("decodes two coalesced frames from a single read")
    func coalescedFrames() throws {
        var decoder = FrameDecoder()
        var blob = FrameEncoder.encode(kind: .ping, payload: Data("a".utf8))
        blob.append(FrameEncoder.encode(kind: .pong, payload: Data("bb".utf8)))
        decoder.append(blob)

        let frames = try drain(&decoder)
        #expect(frames.count == 2)
        #expect(frames[0] == Frame(kind: .ping, payload: Data("a".utf8)))
        #expect(frames[1] == Frame(kind: .pong, payload: Data("bb".utf8)))
    }

    @Test("reassembles a frame split across reads")
    func splitFrame() throws {
        let original = Frame(kind: .command, payload: Data("split me".utf8))
        let encoded = FrameEncoder.encode(original)

        for splitPoint in 1..<encoded.count {
            var decoder = FrameDecoder()
            decoder.append(encoded.prefix(splitPoint))
            #expect(try decoder.next() == nil, "should not decode at split point \(splitPoint)")

            decoder.append(encoded.suffix(from: splitPoint))
            #expect(try decoder.next() == original, "should decode after completing at \(splitPoint)")
        }
    }

    @Test("buffers a header that arrives one byte at a time")
    func byteAtATime() throws {
        let original = Frame(kind: .clientHello, payload: Data("abc".utf8))
        var decoder = FrameDecoder()
        for byte in FrameEncoder.encode(original) {
            decoder.append(Data([byte]))
            _ = try decoder.next()
        }
        decoder.append(Data())
        var fresh = FrameDecoder()
        fresh.append(FrameEncoder.encode(original))
        #expect(try drain(&fresh) == [original])
    }

    /// Refused before allocating, or four bytes of input exhaust host memory.
    @Test("rejects an oversized declared length without buffering it")
    func oversizedRejected() {
        var decoder = FrameDecoder()
        decoder.append(Data([0xFF, 0xFF, 0xFF, 0xFF, MessageKind.command.rawValue]))

        #expect(throws: FramingError.frameTooLarge(declared: 0xFFFF_FFFF)) {
            _ = try decoder.next()
        }
    }

    @Test("rejects a zero-length frame")
    func zeroLengthRejected() {
        var decoder = FrameDecoder()
        decoder.append(Data([0x00, 0x00, 0x00, 0x00]))
        #expect(throws: FramingError.zeroLengthFrame) { _ = try decoder.next() }
    }

    @Test("rejects an unknown kind rather than silently skipping it")
    func unknownKindRejected() {
        var decoder = FrameDecoder()
        decoder.append(Data([0x00, 0x00, 0x00, 0x01, 0xFE]))
        #expect(throws: FramingError.unknownKind(0xFE)) { _ = try decoder.next() }
    }

    @Test("round-trips a payload larger than the read buffer")
    func largePayload() throws {
        let payload = Data((0..<(1 << 20)).map { UInt8($0 & 0xFF) }) // 1 MiB
        let original = Frame(kind: .videoFrame, payload: payload)

        var decoder = FrameDecoder()
        let encoded = FrameEncoder.encode(original)
        var offset = encoded.startIndex
        var decoded: Frame?
        while offset < encoded.endIndex {
            let end = encoded.index(offset, offsetBy: 8192, limitedBy: encoded.endIndex) ?? encoded.endIndex
            decoder.append(encoded[offset..<end])
            offset = end
            while let frame = try decoder.next() { decoded = frame }
        }

        #expect(decoded == original)
    }

    @Test("buffer does not grow without bound across many frames")
    func bufferStaysBounded() throws {
        var decoder = FrameDecoder()
        let frame = FrameEncoder.encode(kind: .ping)
        for _ in 0..<20_000 {
            decoder.append(frame)
            while try decoder.next() != nil {}
        }
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test("the default cap is 16 MiB", arguments: [
        (FrameDecoder.maxFrameLength, true),
        (FrameDecoder.maxFrameLength + 1, false),
    ])
    func capBoundary(declared: UInt32, shouldSucceed: Bool) throws {
        var decoder = FrameDecoder()
        var header = Data()
        header.append(UInt8(truncatingIfNeeded: declared >> 24))
        header.append(UInt8(truncatingIfNeeded: declared >> 16))
        header.append(UInt8(truncatingIfNeeded: declared >> 8))
        header.append(UInt8(truncatingIfNeeded: declared))
        header.append(MessageKind.command.rawValue)
        decoder.append(header)

        if shouldSucceed {
            #expect(try decoder.next() == nil) // header accepted, payload still missing
        } else {
            #expect(throws: FramingError.frameTooLarge(declared: declared)) {
                _ = try decoder.next()
            }
        }
    }
}
