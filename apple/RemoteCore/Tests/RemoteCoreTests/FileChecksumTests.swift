import Foundation
import Testing

@testable import RemoteCore

@Suite struct FileChecksumTests {
    @Test func knownDigestsMatch() {
        #expect(FileChecksum.of(Data()) == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(FileChecksum.of(Data("abc".utf8)) == "900150983cd24fb0d6963f7d28e17f72")
    }

    @Test func piecesGiveTheDigestOfTheWhole() {
        var checksum = FileChecksum()
        checksum.update(Data("a".utf8))
        checksum.update(Data("bc".utf8))
        #expect(checksum.finalized() == "900150983cd24fb0d6963f7d28e17f72")
    }

    @Test func aFileIsHashedInSmallReads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        #expect(try FileChecksum.ofFile(at: url, pieceBytes: 2) == "900150983cd24fb0d6963f7d28e17f72")
    }
}
