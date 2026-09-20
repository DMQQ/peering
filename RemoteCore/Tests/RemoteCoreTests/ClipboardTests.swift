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
        // **The shape a Mac that has not updated sends**, and the one case where a strict decoder
        // would break something that works today: the payload has no `kind` in it at all, and
        // reading it as an error would turn every copied line of text into silence.
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
        // The check lives on the payload rather than at each point of use, so both ends ask the
        // same question and get the same answer. A caller that skipped it would send something
        // the far end refuses to buffer.
        let tooBig = Data(count: ClipboardLimits.maxImageBytes + 1)
        #expect(ClipboardPayload.image(tooBig).carriedImage == nil)
    }

    @Test("a picture at the limit is carried")
    func pictureAtTheLimitIsCarried() {
        // The boundary in the other direction: a guard set one byte inside the limit would refuse
        // the largest picture the limit promises, which is the only case it must not.
        let atTheLimit = Data(count: ClipboardLimits.maxImageBytes)
        #expect(ClipboardPayload.image(atTheLimit).carriedImage?.count == ClipboardLimits.maxImageBytes)
    }

    @Test("a text payload carries no picture even if one is set")
    func kindDecidesNotTheField() {
        // The reason `kind` is a field rather than "whichever of the two is set". A payload that
        // says text and happens to hold bytes must be read as text by both ends, or the two of
        // them would disagree depending on the order they checked in.
        let contradictory = ClipboardPayload(kind: .text, text: "hi", image: Data([1, 2, 3]))
        #expect(contradictory.carriedImage == nil)
    }
}

@Suite("Getting a pasteboard across")
struct ClipboardTransferTests {
    /// A payload the size of a small screenshot, and one that is certainly over the limit.
    private func payload(_ bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8($0 % 251) })
    }

    /// Every frame through a reassembler, as the far end would see them.
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
        // The property that keeps the ordinary clipboard from paying for the extraordinary one.
        // A text payload that was cut up would work, and would make every copy a burst of frames
        // on a channel that carries keystrokes.
        let text = Data(#"{"kind":"text","text":"hello"}"#.utf8)
        #expect(ClipboardTransfer.needsChunking(text) == false)

        let frames = ClipboardTransfer.frames(kind: .clipboardContent, payload: text, frameID: 1)
        #expect(frames.count == 1)
        #expect(frames[0].kind == .clipboardContent)
    }

    @Test("a picture arrives whole and byte for byte")
    func pictureRoundTripsThroughChunks() throws {
        // The whole feature in one test. Two megabytes is over the control channel's cap by a
        // factor of thirty, so this cannot pass unless the cut and the reassembly agree about
        // the header, the ordering and the last piece.
        let picture = payload(2 * 1024 * 1024)
        #expect(ClipboardTransfer.needsChunking(picture))

        let frames = ClipboardTransfer.frames(kind: .clipboardContent, payload: picture, frameID: 7)
        #expect(frames.count > 1)
        #expect(frames.allSatisfy { $0.kind == .videoChunk })
        // Every piece has to fit a control message on its own, header and all, or the protocol
        // refuses it at the far end and the picture never completes.
        #expect(frames.allSatisfy { $0.payload.count <= ProtocolInfo.maxControlPayload })

        let whole = try #require(reassemble(frames))
        #expect(whole.kind == .clipboardContent)
        #expect(whole.payload == picture)
    }

    @Test("the chunks say which lane they belong to")
    func innerKindIsReadable() throws {
        // What the client routes on. Both lanes number their frames from one and both arrive as
        // `videoChunk`, so this byte is the only thing that can tell them apart.
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
        // Not a truncated one. Half a screenshot is not a smaller screenshot, and a payload the
        // far end would refuse to buffer is better never sent than sent and dropped.
        let huge = Data(count: ClipboardLimits.maxReassembledBytes + 1)
        #expect(ClipboardTransfer.frames(kind: .command, payload: huge, frameID: 9).isEmpty)
    }

    @Test("the picture's lane and the clipboard's cannot corrupt each other")
    func lanesDoNotShareAnAssembler() throws {
        // **The bug a shared assembler would produce, and the reason there are two.** Both lanes
        // number from one, and a chunk belonging to a newer frame throws away what was being
        // assembled. Interleaved, a shared assembler would abandon the picture on every clipboard
        // frame and the clipboard on every picture, so a screenshot would never finish arriving
        // on a session whose screen was moving.
        var pictures = VideoChunkReassembler()
        var clipboard = ClipboardTransfer.reassembler()

        let picture = ClipboardTransfer.frames(kind: .videoFrame, payload: payload(256 * 1024), frameID: 1)
        let shot = ClipboardTransfer.frames(kind: .clipboardContent, payload: payload(256 * 1024), frameID: 1)

        // The two streams interleaved piece by piece, which is what one TCP connection does.
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
        // The trap this type exists for. `nil` is a peer built before the field existed, which has
        // never heard of the command, and reading it as "not false, so probably fine" is the
        // natural mistake and an invisible one: it only shows up when one end is old. Both ends
        // speak the same protocol version either way, so this flag is the only thing that tells
        // them apart.
        #expect(ClipboardImages.maySend(toHostDeclared: true) == true)
        #expect(ClipboardImages.maySend(toHostDeclared: false) == false)
        #expect(ClipboardImages.maySend(toHostDeclared: nil) == false)

        #expect(ClipboardImages.mayReceive(clientDeclared: true) == true)
        #expect(ClipboardImages.mayReceive(clientDeclared: false) == false)
        #expect(ClipboardImages.mayReceive(clientDeclared: nil) == false)
    }
}
