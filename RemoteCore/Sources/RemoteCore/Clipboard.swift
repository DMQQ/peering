import Foundation

/// What either end will carry on a pasteboard, and how it gets there.
///
/// A picture does not fit in a control message: ``ProtocolInfo/maxControlPayload`` is 64 KB and a
/// Retina screenshot is a couple of megabytes, so text travels as a single frame and a picture as
/// one frame or several. The limits are values here rather than in either app, so both ends agree.
public enum ClipboardLimits {
    /// The most picture either end will carry, in the PNG bytes that actually travel.
    ///
    /// Deliberately the same figure the file browser puts on a picture (`imagePreviewByteLimit` in
    /// MacCastKit): a picture the browser can show but the clipboard cannot carry would be the app
    /// contradicting itself, and two limits would drift apart the first time one was tuned.
    ///
    /// The transfer rides the control channel in 16 KB pieces, so keystrokes and pings keep
    /// flowing past it; what the size costs is time, not correctness.
    public static let maxImageBytes = 8 * 1024 * 1024

    /// The most that will be buffered while one clipboard frame is put back together.
    ///
    /// Above ``maxImageBytes`` by the inflation of the envelope: the guard is on the encoded form
    /// held in memory, and base64 turns every three bytes into four. Set at the limit itself it
    /// would refuse the largest picture the limit allows.
    public static let maxReassembledBytes = 12 * 1024 * 1024
}

/// Cuts a clipboard payload into frames a control message can hold, and sets the limit on one.
///
/// The same mechanism the picture takes when it falls back to the control channel:
/// ``VideoChunkEncoder`` is generic over ``MessageKind`` and ``VideoChunkReassembler`` returns
/// whatever was cut up.
///
/// A payload that already fits travels as itself, under its own kind, so a line of text is one
/// frame and stays readable in a log.
public enum ClipboardTransfer {
    /// The frames one clipboard payload becomes on the wire.
    ///
    /// - Returns: an empty array for a payload over ``ClipboardLimits/maxReassembledBytes``;
    ///   nothing is sent in its place, since half a picture is not a smaller picture. The caller is
    ///   expected to have refused it already, which is what ``ClipboardPayload/carriedImage`` is for.
    public static func frames(kind: MessageKind, payload: Data, frameID: UInt32) -> [Frame] {
        guard payload.count <= ClipboardLimits.maxReassembledBytes else { return [] }
        return VideoChunkEncoder.encode(kind: kind, payload: payload, frameID: frameID)
    }

    /// Whether a payload has to be cut up at all.
    ///
    /// Asked by nothing on the send path, which lets the encoder decide, and asked by the tests.
    public static func needsChunking(_ payload: Data) -> Bool {
        payload.count > VideoChunk.maxPayload
    }

    /// A reassembler for the clipboard lane.
    ///
    /// Separate from the video lane's, necessarily: both arrive as ``MessageKind/videoChunk``
    /// frames on the same connection and both number their frames from one, and a chunk belonging
    /// to a different frame discards whatever was being assembled.
    public static func reassembler() -> VideoChunkReassembler {
        VideoChunkReassembler(maxReassembled: ClipboardLimits.maxReassembledBytes)
    }
}

/// Whether a picture may be carried on the clipboard, and the questions that have to be answered
/// before one is sent.
///
/// In `RemoteCore` rather than in the app, because both ends ask it: the Mac asks it of the
/// client's hello and the client asks it of the Mac's, so a rule kept on one side would be written
/// again on the other.
///
/// Each flag it reads is optional and additive: three states, and only one of them is permission.
public enum ClipboardImages {
    /// Whether a client may push a picture to this Mac.
    ///
    /// An explicit `true` and nothing else:
    ///
    /// - `true` is a Mac that has heard the question and can take the command.
    /// - `nil` is a Mac built before the field existed. An unknown command is a decode failure in
    ///   the middle of a session, so sending would trade a working clipboard for a dropped session.
    /// - `false` is a Mac that knows about the command and has said it will not take it.
    public static func maySend(toHostDeclared declared: Bool?) -> Bool {
        declared == true
    }

    /// Whether a Mac may push a picture to this client.
    ///
    /// Asked by the Mac of the client's own hello, and the same three states. A client too old to
    /// read a picture would feed the Mac's chunked payload to its picture lane's assembler and
    /// stutter through a screenshot it did not ask for.
    public static func mayReceive(clientDeclared declared: Bool?) -> Bool {
        declared == true
    }
}
