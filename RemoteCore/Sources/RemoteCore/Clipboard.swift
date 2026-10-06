import Foundation

/// A picture does not fit in a control message (``ProtocolInfo/maxControlPayload`` is 64 KB), so it is chunked.
public enum ClipboardLimits {
    /// Matches the file browser's `imagePreviewByteLimit` so the two limits cannot disagree.
    public static let maxImageBytes = 8 * 1024 * 1024

    /// Above ``maxImageBytes`` because the guard is on the base64 form (4/3 inflation).
    public static let maxReassembledBytes = 12 * 1024 * 1024
}

public enum ClipboardTransfer {
    /// Empty for a payload over ``ClipboardLimits/maxReassembledBytes``: half a picture is not a smaller picture.
    public static func frames(kind: MessageKind, payload: Data, frameID: UInt32) -> [Frame] {
        guard payload.count <= ClipboardLimits.maxReassembledBytes else { return [] }
        return VideoChunkEncoder.encode(kind: kind, payload: payload, frameID: frameID)
    }

    public static func needsChunking(_ payload: Data) -> Bool {
        payload.count > VideoChunk.maxPayload
    }

    /// Separate from the video lane's: both use `videoChunk` frames numbered from one, and a foreign chunk discards what is being assembled.
    public static func reassembler() -> VideoChunkReassembler {
        VideoChunkReassembler(maxReassembled: ClipboardLimits.maxReassembledBytes)
    }
}

public enum ClipboardImages {
    /// Explicit `true` only: `nil` is a Mac built before the field, and an unknown command is a decode failure mid-session.
    public static func maySend(toHostDeclared declared: Bool?) -> Bool {
        declared == true
    }

    /// A client too old to read a picture would feed the chunked payload to its video assembler.
    public static func mayReceive(clientDeclared declared: Bool?) -> Bool {
        declared == true
    }
}
