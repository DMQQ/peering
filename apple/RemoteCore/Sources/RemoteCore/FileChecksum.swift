import CryptoKit
import Foundation

/// MD5 as a corruption check on file transfers, not as security: the channel is already
/// authenticated and encrypted, so this only catches a file that was written or read wrongly.
public struct FileChecksum: Sendable {
    private var hasher = Insecure.MD5()

    public init() {}

    public mutating func update(_ data: Data) {
        hasher.update(data: data)
    }

    public func finalized() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func of(_ data: Data) -> String {
        var checksum = FileChecksum()
        checksum.update(data)
        return checksum.finalized()
    }

    /// Reads in pieces, so a multi-gigabyte file is never held in memory.
    public static func ofFile(at url: URL, pieceBytes: Int = 1_048_576) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var checksum = FileChecksum()
        while let piece = try handle.read(upToCount: pieceBytes), !piece.isEmpty {
            checksum.update(piece)
        }
        return checksum.finalized()
    }
}
