import CoreGraphics
import RemoteCore

/// Which picture the stream is showing, as far as this end can name it.
///
/// **The protocol never says "the capture source changed".** A switch reaches the phone as one
/// thing: a new ``VideoStreamConfig``, carrying a codec, a size and parameter sets, and no name
/// for what is being captured. The same message arrives for several other reasons, and not one
/// of them is rare. The picture moves between the direct channel and the control channel. The
/// video connection re-attaches after a drop. The host's codec changes, or its capture
/// resolution does. A phone that reset its zoom whenever a config arrived would throw the user's
/// place away every time the encoder or the network did something, which is a picture that jumps
/// for reasons that have nothing to do with what is on it.
///
/// So the identity is put together from the two things this end does know.
///
/// **The source** is the one the phone believes is being captured, ``SessionModel/activeSourceID``,
/// written when a source is chosen rather than when its picture arrives. It is what makes two
/// sources of the same size two sources: two identical monitors side by side are the case that
/// leaves the size alone useless as an identity.
///
/// **The size** is the stream's own, the only part of the picture the stream itself describes.
/// It is what tells a switch apart from a refresh when the phone did not make the switch. The Mac
/// switches capture on its own in exactly one place today, when a client asks it to open an
/// application: the host launches the app and points capture at it, and the phone is never told
/// the new source's name. A display's size, though, is fixed and known from the catalogue, so a
/// config for a source the phone believes is a display, at a size that display is not, is not the
/// picture the phone thinks it is looking at.
public struct PictureIdentity: Equatable {
    public init(sourceID: String?, pixelSize: CGSize, contentMovesOnItsOwn: Bool) {
        self.sourceID = sourceID
        self.pixelSize = pixelSize
        self.contentMovesOnItsOwn = contentMovesOnItsOwn
    }

    /// The capture source this phone believes the picture belongs to.
    ///
    /// `nil` until the Mac has sent a catalogue, which is the only thing that names sources. See
    /// ``change(to:)`` for why a nameless picture is never read as a switch.
    public let sourceID: String?
    /// The stream's own size, **in pixels**. Pixels rather than points for the same reason the
    /// config is: a Retina display reports its size in points at half the number.
    public let pixelSize: CGSize
    /// Whether this source's size changes without the source changing: for the source above,
    /// this is ``CaptureSource/contentMovesOnItsOwn``, carried here rather than looked up
    /// again because the picture and the catalogue it was named from are not read at the same
    /// moment.
    ///
    /// False for a display, whose surface is fixed for the life of the stream. True for a window
    /// or an application, which the person at the Mac drags and resizes whenever they like and
    /// which therefore arrives at a new size several times in a session with nothing having been
    /// switched. Unknown counts as true, and that is the deliberate half: see ``change(to:)``.
    public let contentMovesOnItsOwn: Bool

    /// What a zoom and a pan, chosen against this picture, should do when `next` describes the
    /// stream again.
    public enum Change: Equatable {
        /// The same source at the same size. This is the stream described again, which is what a
        /// change of lane, a re-attach, or a fresh set of parameter sets from a rebuilt encoder
        /// looks like on the wire. Nothing on screen should move.
        case unchanged
        /// The same source at a new size: a window or an application was resized while it was
        /// being captured.
        case resized
        /// A picture the zoom and the pan on screen were not chosen for.
        case replaced
    }

    /// How the arrival of `next` reads against this picture.
    public func change(to next: PictureIdentity) -> Change {
        // The names are compared only when both ends have one. A picture described before the
        // catalogue arrived is nameless, and the same picture described again after it is not a
        // source change: the name has caught up with the picture, which is the ordinary business
        // of a session's first seconds rather than news about the Mac.
        if let mine = sourceID, let theirs = next.sourceID, mine != theirs { return .replaced }
        if pixelSize == next.pixelSize { return .unchanged }

        // A display cannot change size without the source changing. Its surface is fixed for the
        // life of the stream, so a new size means a different display, or the same display at a
        // new mode, and the rectangle the pan was measured against is gone either way.
        //
        // A window or an application resizes whenever the person at the Mac likes, and that is a
        // change to the picture rather than to what is being captured. An unknown source is
        // treated the same way, because the two mistakes are not equal: keeping a magnification
        // that no longer fits costs one pinch to undo, and throwing away the place somebody was
        // reading costs them the place they were reading.
        return contentMovesOnItsOwn ? .resized : .replaced
    }
}

extension PictureIdentity {
    /// The picture a video config describes, named as far as this end can name it.
    ///
    /// The catalogue is the only thing in a session that says what a source *is*, so it is also
    /// the only place the answer to "can this one change size on its own" comes from. A source
    /// with no catalogue entry behind it is left as unknown rather than guessed at, which
    /// ``contentMovesOnItsOwn`` reads as "free to move", and that direction is the deliberate
    /// one, because keeping a magnification that no longer fits costs one pinch and throwing away
    /// the place somebody was reading costs them the place they were reading.
    ///
    /// Here rather than on the model because it is a question about a config and a catalogue, and
    /// the answer is what the zoom's whole set of decisions is made against.
    public static func forStream(
        _ config: VideoStreamConfig,
        activeSourceID: String?,
        catalog: CaptureCatalog?,
        // The source itself where the caller has it, which is the one case the catalogue cannot
        // answer for. Optional so that the two ends that build a picture from a config and a
        // catalogue alone do not have to invent one.
        source: CaptureSource? = nil
    ) -> PictureIdentity {
        let descriptor = activeSourceID.flatMap { id in catalog?.all.first { $0.id == id } }

        // **A mosaic is known without the catalogue, because this end is the one that built it.**
        // It has no row in the catalogue and never will: it is something the app asked the Mac
        // for rather than something the Mac offers. Left to the descriptor lookup below it would
        // take the unknown answer, which reads as a window, and a window keeps its magnification
        // when the picture changes size — so a canvas that was rearranged would go on holding a
        // zoom chosen for the arrangement that is gone. See ``CaptureSource/contentMovesOnItsOwn``.
        let movesOnItsOwn = source?.isMosaic == true
            ? false
            : descriptor?.source.contentMovesOnItsOwn ?? true

        return PictureIdentity(
            sourceID: activeSourceID,
            pixelSize: CGSize(width: config.pixelWidth, height: config.pixelHeight),
            contentMovesOnItsOwn: movesOnItsOwn
        )
    }
}
