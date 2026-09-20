import Foundation

/// What either end will carry on a pasteboard, and how it gets there.
///
/// **A picture does not fit in a control message, and that is the whole of why this file exists.**
/// ``ProtocolInfo/maxControlPayload`` is 64 KB and a Retina screenshot is a couple of megabytes, so
/// text and pictures cannot travel the same way: text is one frame, and a picture is one frame or
/// several. The rules are here, in values, rather than in either app, so that both ends agree about
/// the limits and so the arithmetic can be proved without a network or a pasteboard.
public enum ClipboardLimits {
    /// The most picture either end will carry, in the PNG bytes that actually travel.
    ///
    /// Deliberately the same figure the file browser puts on a picture (see `imagePreviewByteLimit`
    /// in MacCastKit), and the same rather than a second number for a reason the user would feel:
    /// being able to look at a picture on the Mac through the browser and then not being able to
    /// copy it would be the app contradicting itself, and the two limits would drift apart the
    /// first time one of them was tuned.
    ///
    /// What the size costs is time, not correctness. Eight megabytes of PNG is about eleven of
    /// base64 on the wire, which over a slow relay is most of a minute, and the transfer rides the
    /// control channel in 16 KB pieces so keystrokes and pings keep flowing past it. The picture is
    /// the largest thing this protocol carries and it is still a thing a person asked for by hand.
    public static let maxImageBytes = 8 * 1024 * 1024

    /// The most that will be buffered while one clipboard frame is put back together.
    ///
    /// Above ``maxImageBytes`` by the inflation the envelope adds, because the guard is on what is
    /// held in memory and what is held is the encoded form: base64 turns every three bytes into
    /// four, and the JSON around it adds a little more. A guard set at the limit itself would
    /// refuse the largest picture the limit allows, which is the one case it must not.
    public static let maxReassembledBytes = 12 * 1024 * 1024
}

/// Cuts a clipboard payload into frames a control message can hold, and sets the limit on one.
///
/// **The same mechanism the picture takes when it falls back to the control channel**, reused
/// rather than written a second time. ``VideoChunkEncoder`` is already generic over ``MessageKind``
/// and ``VideoChunkReassembler`` already returns whatever was cut up, so neither end supplies
/// anything but the frame to send. The name is the debt: the type was born for a keyframe and now
/// carries a command too.
///
/// **A payload that already fits travels as itself**, under its own kind, exactly as
/// ``VideoChunkEncoder`` has always done it. So the common case, a line of text, is one frame and
/// stays readable in a log, and nothing about the ordinary path changed when the picture was added
/// to it.
public enum ClipboardTransfer {
    /// The frames one clipboard payload becomes on the wire.
    ///
    /// - Returns: an empty array for a payload over ``ClipboardLimits/maxReassembledBytes``.
    ///   Nothing is sent in its place: there is no degraded version of a picture, and half of one
    ///   is not a smaller picture. The caller is expected to have refused it in front of the user
    ///   already, which is what ``ClipboardPayload/carriedImage`` is for.
    public static func frames(kind: MessageKind, payload: Data, frameID: UInt32) -> [Frame] {
        guard payload.count <= ClipboardLimits.maxReassembledBytes else { return [] }
        return VideoChunkEncoder.encode(kind: kind, payload: payload, frameID: frameID)
    }

    /// Whether a payload has to be cut up at all.
    ///
    /// Asked by nothing on the send path, which lets the encoder decide, and asked by the tests:
    /// "does a text payload stay one frame" is the property that keeps the ordinary clipboard from
    /// paying for the extraordinary one.
    public static func needsChunking(_ payload: Data) -> Bool {
        payload.count > VideoChunk.maxPayload
    }

    /// A reassembler for the clipboard lane.
    ///
    /// **A separate one from the video lane's, and it has to be.** Both lanes arrive as
    /// ``MessageKind/videoChunk`` frames on the same connection and both number their frames from
    /// one, so two streams sharing an assembler would interleave and each would be read as a
    /// contradiction of the other: a chunk belonging to a different frame discards what was being
    /// assembled, which is right for one stream and destruction for two.
    public static func reassembler() -> VideoChunkReassembler {
        VideoChunkReassembler(maxReassembled: ClipboardLimits.maxReassembledBytes)
    }
}

/// Whether a picture may be carried on the clipboard, and the questions that have to be answered
/// before one is sent.
///
/// **In `RemoteCore` rather than in the app, because both ends ask it.** The Mac asks it of the
/// client's hello and the client asks it of the Mac's, so a rule kept on one side would be a rule
/// the other side had to write again, and the two would be free to disagree about the same wire
/// field. See ``PicturePause`` in MacCastKit for the same idea where only one end asks.
///
/// Each flag it reads is optional and additive, so each has three states and only one of them is
/// permission.
public enum ClipboardImages {
    /// Whether a client may push a picture to this Mac.
    ///
    /// An explicit `true` and nothing else:
    ///
    /// - `true` is a Mac that has heard the question and can take the command.
    /// - `nil` is a Mac built before the field existed. It has never heard the question, and an
    ///   unknown command is a decode failure **in the middle of a session** rather than a feature
    ///   that quietly does not work. Sending to it would trade a working clipboard for a dropped
    ///   session, which is a bad bargain for a screenshot.
    /// - `false` is a Mac that knows about the command and has said it will not take it.
    public static func maySend(toHostDeclared declared: Bool?) -> Bool {
        declared == true
    }

    /// Whether a Mac may push a picture to this client.
    ///
    /// Asked by the Mac of the client's own hello, and the same three states. The failure it rules
    /// out is not a dropped session here but something quieter: a client too old to read a picture
    /// receives the Mac's chunked payload, does not know what it is, and feeds it to its picture
    /// lane's assembler, which carries the pieces for as long as the transfer lasts. The user sees
    /// a screenshot they did not ask for and a picture that stutters while it arrives.
    public static func mayReceive(clientDeclared declared: Bool?) -> Bool {
        declared == true
    }
}
