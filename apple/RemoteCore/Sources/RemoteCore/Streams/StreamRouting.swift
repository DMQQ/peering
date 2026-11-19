import Foundation

/// Which stream a frame travels on, or nil for the frames that never do: the handshake and pairing, errors, the lane's own bootstrap and traffic, video and audio.
public enum StreamRouting {
    public static func stream(for frame: Frame) -> StreamID? {
        switch frame.kind {
        case .command, .catalog, .setCaptureSource, .notice, .clipboardContent, .textFocus, .fieldState,
             .pointerReport, .clientState, .activityToken:
            return .interactive
        case .ping, .pong:
            return .pulse
        case .terminalRequest, .terminalEvent:
            return fileCases.contains(firstKey(of: frame.payload) ?? "") ? .files : .terminal
        case .agentRequest, .agentEvent, .previewRequest, .previewEvent:
            return .agent
        case .connectionRole, .clientHello, .serverHello, .pairConfirm, .pairResult, .pairCommit, .pairReveal,
             .error, .videoConfig, .videoFrame, .audioConfig, .audioFrame, .videoChunk, .videoTransport,
             .videoKeyRequest, .videoKey, .directProbe, .directCommand, .directCandidates, .controlPipe, .stream:
            return nil
        }
    }

    /// The Codable enums for terminal traffic encode as `{"caseName":{...}}`, so the case is the first key. Read from the bytes: decoding a sixteen kilobyte transfer chunk to learn which stream it goes on would cost more than sending it.
    static func firstKey(of payload: Data) -> String? {
        let bytes = [UInt8](payload.prefix(48))
        guard bytes.count > 3, bytes[0] == UInt8(ascii: "{"), bytes[1] == UInt8(ascii: "\"") else { return nil }
        guard let end = bytes[2...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: bytes[2..<end], as: UTF8.self)
    }

    private static let fileCases: Set<String> = [
        "listDirectory", "readFile", "readRange", "archiveFolder", "beginWrite", "writeChunk", "changeFile",
        "directory", "fileContents", "fileRange", "archiveReady", "transferFailure", "browseFailure",
        "wroteFile", "writeFailure", "fileOperationDone", "fileOperationFailure",
    ]
}
