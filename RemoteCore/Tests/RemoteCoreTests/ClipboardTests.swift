import Foundation
import Testing

@testable import RemoteCore

@Suite("What a pasteboard carries")
struct ClipboardPayloadTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test("a payload written before there was a kind is read as text")
    func oldPayloadDecodesAsText() throws {
        // An older Mac sends no `kind` at all; a strict decoder would turn every copied line into silence.
        let older = Data(#"{"text":"hello"}"#.utf8)
        let payload = try MessageCodec.decode(ClipboardPayload.self, from: older)

        #expect(payload.kind == .text)
        #expect(payload.text == "hello")
        #expect(payload.image == nil)
    }

    @Test("text and a picture survive the codec")
    func roundTrips() throws {
        let text = try roundTrip(ClipboardPayload.text("héllo 👋 世界"))
        #expect(text.kind == .text)
        #expect(text.text == "héllo 👋 世界")
        #expect(text.image == nil)

        let picture = try roundTrip(ClipboardPayload.image(Data([0x89, 0x50, 0x4E, 0x47])))
        #expect(picture.kind == .image)
        #expect(picture.image == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(picture.text == nil)
    }

    @Test("a picture over the limit is not carried")
    func oversizePictureIsRefused() {
        let tooBig = Data(count: ClipboardLimits.maxImageBytes + 1)
        #expect(ClipboardPayload.image(tooBig).carriedImage == nil)
    }

    @Test("a picture at the limit is carried")
    func pictureAtTheLimitIsCarried() {
        // A guard one byte inside the limit would refuse the largest picture it promises.
        let atTheLimit = Data(count: ClipboardLimits.maxImageBytes)
        #expect(ClipboardPayload.image(atTheLimit).carriedImage?.count == ClipboardLimits.maxImageBytes)
    }

    @Test("a text payload carries no picture even if one is set")
    func kindDecidesNotTheField() {
        // A payload saying text that also holds bytes must read as text at both ends.
        let contradictory = ClipboardPayload(kind: .text, text: "hi", image: Data([1, 2, 3]))
        #expect(contradictory.carriedImage == nil)
    }
}

@Suite("Getting a pasteboard across")
struct ClipboardTransferTests {
    private func payload(_ bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8($0 % 251) })
    }

    private func reassemble(_ frames: [Frame]) -> Frame? {
        var assembler = ClipboardTransfer.reassembler()
        var result: Frame?
        for frame in frames {
            if let whole = try? assembler.ingest(frame) { result = whole }
        }
        return result
    }

    @Test("a line of text stays one frame")
    func textIsNotChunked() {
        // A text payload that was cut up would turn every copy into a burst of frames on the keystroke channel.
        let text = Data(#"{"kind":"text","text":"hello"}"#.utf8)
        #expect(ClipboardTransfer.needsChunking(text) == false)

        let frames = ClipboardTransfer.frames(kind: .clipboardContent, payload: text, frameID: 1)
        #expect(frames.count == 1)
        #expect(frames[0].kind == .clipboardContent)
    }

    @Test("a picture arrives whole and byte for byte")
    func pictureRoundTripsThroughChunks() throws {
        let picture = payload(2 * 1024 * 1024)
        #expect(ClipboardTransfer.needsChunking(picture))

        let frames = ClipboardTransfer.frames(kind: .clipboardContent, payload: picture, frameID: 7)
        #expect(frames.count > 1)
        #expect(frames.allSatisfy { $0.kind == .videoChunk })
        #expect(frames.allSatisfy { $0.payload.count <= ProtocolInfo.maxControlPayload })

        let whole = try #require(reassemble(frames))
        #expect(whole.kind == .clipboardContent)
        #expect(whole.payload == picture)
    }

    @Test("the chunks say which lane they belong to")
    func innerKindIsReadable() throws {
        // Both lanes arrive as `videoChunk`, so this kind byte is all that tells them apart.
        let frames = ClipboardTransfer.frames(
            kind: .clipboardContent,
            payload: payload(64 * 1024),
            frameID: 3
        )
        let first = try #require(frames.first)
        #expect(VideoChunk.innerKind(of: first) == .clipboardContent)

        let command = ClipboardTransfer.frames(kind: .command, payload: payload(64 * 1024), frameID: 4)
        #expect(VideoChunk.innerKind(of: try #require(command.first)) == .command)
    }

    @Test("a payload over the limit sends nothing")
    func oversizePayloadIsNotSent() {
        // Half a screenshot is not a smaller screenshot: never sent rather than sent and dropped.
        let huge = Data(count: ClipboardLimits.maxReassembledBytes + 1)
        #expect(ClipboardTransfer.frames(kind: .command, payload: huge, frameID: 9).isEmpty)
    }

    @Test("the picture's lane and the clipboard's cannot corrupt each other")
    func lanesDoNotShareAnAssembler() throws {
        // A shared assembler would abandon the picture on every clipboard frame, since a chunk of a newer frame discards the one in progress.
        var pictures = VideoChunkReassembler()
        var clipboard = ClipboardTransfer.reassembler()

        let picture = ClipboardTransfer.frames(kind: .videoFrame, payload: payload(256 * 1024), frameID: 1)
        let shot = ClipboardTransfer.frames(kind: .clipboardContent, payload: payload(256 * 1024), frameID: 1)

        var wholePicture: Frame?
        var wholeShot: Frame?
        for index in 0..<max(picture.count, shot.count) {
            if index < picture.count, let whole = try? pictures.ingest(picture[index]) {
                wholePicture = whole
            }
            if index < shot.count, let whole = try? clipboard.ingest(shot[index]) {
                wholeShot = whole
            }
        }

        #expect(wholePicture?.payload == payload(256 * 1024))
        #expect(wholeShot?.payload == payload(256 * 1024))
    }
}

@Suite("When a picture may be sent")
struct ClipboardImagesTests {
    @Test("only an explicit yes is permission")
    func threeStates() {
        // `nil` is a peer built before the field existed; reading it as not-false is an invisible mistake since both ends speak the same version.
        #expect(ClipboardImages.maySend(toHostDeclared: true) == true)
        #expect(ClipboardImages.maySend(toHostDeclared: false) == false)
        #expect(ClipboardImages.maySend(toHostDeclared: nil) == false)

        #expect(ClipboardImages.mayReceive(clientDeclared: true) == true)
        #expect(ClipboardImages.mayReceive(clientDeclared: false) == false)
        #expect(ClipboardImages.mayReceive(clientDeclared: nil) == false)
    }
}
