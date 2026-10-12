import Foundation
import RemoteCore

/// The Mac drops a session whose control message is over `ProtocolInfo.maxControlPayload`, and the resume ladder then replays the same tap. Text is held well under that, since JSON escaping and base64 make a payload larger than the text in it.
public enum ControlTextPolicy {
    public static let maximumBytes = 48 * 1024

    /// A third of the cap in base64 form: a chunk of this size leaves room for the request around it.
    public static let terminalChunkBytes = 24 * 1024

    /// A paste past this is a mistake, not a command, and would hold the control stream for as long as it takes to send.
    public static let maximumTerminalBytes = 1024 * 1024

    public enum Verdict: Equatable, Sendable {
        case fits
        case tooLong(bytes: Int, limit: Int)
    }

    public static func verdict(forClipboardOrPrompt text: String) -> Verdict {
        let bytes = text.utf8.count
        return bytes <= maximumBytes ? .fits : .tooLong(bytes: bytes, limit: maximumBytes)
    }

    public static func verdict(forTerminalInput data: Data) -> Verdict {
        data.count <= maximumTerminalBytes ? .fits : .tooLong(bytes: data.count, limit: maximumTerminalBytes)
    }

    /// Never splits a UTF-8 sequence, so each chunk is valid text on its own and the shell sees the original bytes in order.
    public static func terminalChunks(_ data: Data) -> [Data] {
        var chunks: [Data] = []
        var start = data.startIndex
        while start < data.endIndex {
            var end = min(start + terminalChunkBytes, data.endIndex)
            while end < data.endIndex, end > start, isContinuation(data[end]) { end -= 1 }
            if end == start { end = min(start + terminalChunkBytes, data.endIndex) }
            chunks.append(Data(data[start..<end]))
            start = end
        }
        return chunks
    }

    private static func isContinuation(_ byte: UInt8) -> Bool { byte & 0b1100_0000 == 0b1000_0000 }
}
