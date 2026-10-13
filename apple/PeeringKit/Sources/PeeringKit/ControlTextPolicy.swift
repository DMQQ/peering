import Foundation
import RemoteCore

/// The Mac drops a session whose control message is over `ProtocolInfo.maxControlPayload`, and the resume ladder then replays the same tap.
/// What counts is the JSON that goes on the wire, so every limit here is measured on the encoded message: quotes, backslashes, slashes and control characters grow when escaped, and bytes grow a third in base64 (plus a backslash per slash).
public enum ControlTextPolicy {
    /// Room under the host's limit for anything the measurement does not see.
    public static let margin = 2 * 1024
    public static let maximumEncodedBytes = ProtocolInfo.maxControlPayload - margin

    /// Where a terminal chunk starts out; one that encodes too large is cut down until it fits.
    public static let terminalChunkBytes = 24 * 1024

    /// A paste past this is a mistake, not a command, and would hold the control stream for as long as it takes to send.
    public static let maximumTerminalBytes = 1024 * 1024

    /// The longest escape JSON gives one byte of text (`\u001f`), so text below this size cannot encode past the limit and needs no measuring.
    private static let worstEscapeFactor = 6

    /// Only the length of the envelope matters, and every id is the same length.
    private static let envelopeID = UUID()

    public enum Verdict: Equatable, Sendable {
        case fits
        case tooLong(bytes: Int, limit: Int)
    }

    /// `bytes` is the size of the message as sent, in the larger of the two envelopes this text can travel in.
    public static func verdict(forClipboardOrPrompt text: String) -> Verdict {
        let raw = text.utf8.count
        if raw * worstEscapeFactor + margin <= maximumEncodedBytes { return .fits }
        if raw > maximumEncodedBytes { return .tooLong(bytes: raw, limit: maximumEncodedBytes) }
        let bytes = max(
            encodedSize(RemoteCommand.pushClipboard(text: text)),
            encodedSize(AgentRequest.prompt(sessionID: envelopeID, text: text))
        )
        return bytes <= maximumEncodedBytes ? .fits : .tooLong(bytes: bytes, limit: maximumEncodedBytes)
    }

    /// The paths and the message travel in one request, so it is the pair that has to fit.
    public static func verdict(forCommitOf paths: [String], message: String) -> Verdict {
        let bytes = encodedSize(AgentRequest.commit(sessionID: envelopeID, paths: paths, message: message))
        return bytes <= maximumEncodedBytes ? .fits : .tooLong(bytes: bytes, limit: maximumEncodedBytes)
    }

    public static func verdict(forTerminalInput data: Data) -> Verdict {
        data.count <= maximumTerminalBytes ? .fits : .tooLong(bytes: data.count, limit: maximumTerminalBytes)
    }

    /// Never splits a UTF-8 sequence, so each chunk is valid text on its own and the shell sees the original bytes in order.
    /// Every chunk encodes within ``maximumEncodedBytes``, however its bytes escape.
    public static func terminalChunks(_ data: Data) -> [Data] {
        var chunks: [Data] = []
        var start = data.startIndex
        while start < data.endIndex {
            var length = min(terminalChunkBytes, data.endIndex - start)
            var end = boundary(in: data, from: start, length: length)
            while end - start > 1, encodedSize(TerminalRequest.input(sessionID: envelopeID, data: Data(data[start..<end]))) > maximumEncodedBytes {
                length = (end - start) * 3 / 4
                end = boundary(in: data, from: start, length: length)
            }
            chunks.append(Data(data[start..<end]))
            start = end
        }
        return chunks
    }

    private static func boundary(in data: Data, from start: Int, length: Int) -> Int {
        let limit = min(start + length, data.endIndex)
        var end = limit
        while end < data.endIndex, end > start, isContinuation(data[end]) { end -= 1 }
        return end == start ? limit : end
    }

    private static func encodedSize<T: Encodable>(_ value: T) -> Int {
        (try? MessageCodec.encode(value).count) ?? Int.max
    }

    private static func isContinuation(_ byte: UInt8) -> Bool { byte & 0b1100_0000 == 0b1000_0000 }
}
