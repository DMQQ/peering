import Foundation
import Testing

@testable import RemoteCore

@Suite("Remote file sniffing")
struct RemoteFileKindTests {
    /// The magic number and enough of what follows to be past every offset the table reads. A
    /// real file is longer than its signature, and a sniffer that only ever sees four bytes is a
    /// sniffer nobody has tested the bounds of.
    private func head(_ bytes: [UInt8]) -> Data {
        Data(bytes + Array(repeating: 0x00, count: max(0, 16 - bytes.count)))
    }

    @Test("every raster format is recognised by its own bytes")
    func recognisesRasters() {
        let cases: [(String, Data)] = [
            ("PNG", head([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])),
            ("JPEG", head([0xFF, 0xD8, 0xFF, 0xE0])),
            ("GIF", Data("GIF89a".utf8)),
            // Both byte orders, because a TIFF written on one machine is read on the other.
            ("TIFF little-endian", head([0x49, 0x49, 0x2A, 0x00])),
            ("TIFF big-endian", head([0x4D, 0x4D, 0x00, 0x2A])),
            ("BMP", Data("BM".utf8) + Data(repeating: 0, count: 14)),
            ("WebP", Data("RIFF".utf8) + Data([0x00, 0x00, 0x00, 0x00]) + Data("WEBP".utf8)),
            // An ISO base media file: the brand is what decides, and it sits at offset eight.
            ("HEIC", Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypheic".utf8) + Data(repeating: 0, count: 4)),
            ("AVIF", Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypavif".utf8) + Data(repeating: 0, count: 4)),
        ]

        for (name, bytes) in cases {
            #expect(
                RemoteFileKind.sniff(prefix: bytes, path: "/Users/someone/Desktop/thing") == .image,
                "\(name) was not recognised"
            )
        }
    }

    @Test("a RIFF that is not WebP is not a picture")
    func riffIsNotEnough() {
        // A WAV file, which shares the container and nothing else.
        let wav = Data("RIFF".utf8) + Data([0x00, 0x00, 0x00, 0x00]) + Data("WAVE".utf8)
        #expect(RemoteFileKind.sniff(prefix: wav, path: "/Users/someone/Desktop/thing.wav") == nil)
    }

    @Test("contents decide before the name does")
    func contentsWin() {
        // A file called `.png` that holds text is a text file. The name is a claim and the bytes
        // are the fact, so the bytes are asked first.
        let lying = Data("this is not a picture\n".utf8)
        #expect(RemoteFileKind.sniff(prefix: lying, path: "/Users/someone/Desktop/thing.png") == .text)
    }

    @Test("SVG is found by its name and by its own opening tag")
    func recognisesSVG() {
        let document = Data("<?xml version=\"1.0\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)
        #expect(RemoteFileKind.sniff(prefix: document, path: "/Users/someone/Desktop/logo.svg") == .svg)
        // Reached through a link, or saved without the extension: the opening tag is the fallback.
        #expect(RemoteFileKind.sniff(prefix: document, path: "/Users/someone/Desktop/logo") == .svg)
    }

    @Test("text is what is left after the two pictures")
    func recognisesText() {
        let script = Data("#!/bin/sh\ncd -- /tmp && ./deploy.sh\n".utf8)
        #expect(RemoteFileKind.sniff(prefix: script, path: "/Users/someone/Desktop/deploy.sh") == .text)
        // A plist is XML too, which is why XML alone is not the SVG test.
        let plist = Data("<?xml version=\"1.0\"?>\n<plist><dict/></plist>".utf8)
        #expect(RemoteFileKind.sniff(prefix: plist, path: "/Users/someone/Desktop/thing.plist") == .text)
    }

    @Test("a NUL near the start is still the end of the answer")
    func refusesBinary() {
        let database = Data([0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66, 0x00, 0x01, 0x02])
        #expect(RemoteFileKind.sniff(prefix: database, path: "/Users/someone/Desktop/thing.db") == nil)
    }

    @Test("a prefix too short to hold a signature is judged on what is there")
    func shortPrefixesAreSafe() {
        // Every one of these is shorter than the table's furthest read, and none may trap.
        for bytes in [Data(), Data([0x89]), Data([0x00, 0x00, 0x00, 0x18])] {
            _ = RemoteFileKind.sniff(prefix: bytes, path: "/Users/someone/Desktop/thing")
        }
        // Three bytes of PNG signature is not a PNG, however much it looks like the start of one.
        #expect(RemoteFileKind.sniff(prefix: Data([0x89, 0x50, 0x4E]), path: "/x") == nil)
    }

    @Test("a slice of a file sniffs the same as the whole head")
    func slicedPrefixesAreSafe() {
        // `Data.prefix` keeps the parent's indices, which is how a sniffer that subscripts with
        // integers instead of indices goes wrong on exactly one code path.
        let whole = Data(repeating: 0x41, count: 64) + Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(RemoteFileKind.sniff(prefix: whole.dropFirst(64), path: "/x") == .image)
        #expect(RemoteFileKind.sniff(prefix: whole.prefix(16), path: "/x") == .text)
    }

    @Test("a header that stops mid-character is not called binary")
    func trimsAPartialCharacter() {
        // The probe window can land inside a UTF-8 scalar, and calling a text file binary because
        // the read stopped there is exactly the wrong answer.
        let truncated = Data("hello ☃".utf8).dropLast()
        #expect(RemoteFileKind.sniff(prefix: truncated, path: "/Users/someone/Desktop/notes.txt") == .text)
    }

    @Test("only text is read rather than drawn")
    func drawnIsNotText() {
        #expect(RemoteFileKind.text.isDrawn == false)
        #expect(RemoteFileKind.image.isDrawn)
        #expect(RemoteFileKind.svg.isDrawn)
    }
}
