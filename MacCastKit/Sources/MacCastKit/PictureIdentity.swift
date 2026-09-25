import CoreGraphics
import RemoteCore

/// Which picture the stream is showing, as far as this end can name it.
///
/// The source comes from the stream config itself. A request is intent and can run ahead of the
/// picture; using it as the answer made an old stream look like whatever the phone had just asked
/// for, especially during reconnect and same-sized source switches.
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
    /// The stream's own size, in pixels rather than points, for the same reason the config is: a
    /// Retina display reports its size in points at half the number.
    public let pixelSize: CGSize
    /// Whether this source's size changes without the source changing: this is
    /// ``CaptureSource/contentMovesOnItsOwn``, carried rather than looked up again because the
    /// picture and the catalogue it was named from are not read at the same moment.
    ///
    /// False for a display, whose surface is fixed. True for a window or an application, which the
    /// person at the Mac resizes whenever they like. Unknown counts as true, deliberately: see
    /// ``change(to:)``.
    public let contentMovesOnItsOwn: Bool

    /// What a zoom and a pan, chosen against this picture, should do when `next` describes the
    /// stream again.
    public enum Change: Equatable {
        /// The same source at the same size: the stream described again, as a change of lane, a
        /// re-attach, or a rebuilt encoder does. Nothing on screen should move.
        case unchanged
        /// The same source at a new size: a window or an application was resized while it was
        /// being captured.
        case resized
        /// A picture the zoom and the pan on screen were not chosen for.
        case replaced
    }

    /// How the arrival of `next` reads against this picture.
    public func change(to next: PictureIdentity) -> Change {
        // The names are compared only when both ends have one: a picture described before the
        // catalogue arrived is nameless, and the name catching up with it is not a source change.
        if let mine = sourceID, let theirs = next.sourceID, mine != theirs { return .replaced }
        if pixelSize == next.pixelSize { return .unchanged }

        // A display's surface is fixed for the life of the stream, so a new size means the rectangle
        // the pan was measured against is gone. A window or an application resizes whenever the person
        // at the Mac likes, and an unknown source counts as the same.
        return contentMovesOnItsOwn ? .resized : .replaced
    }
}

extension PictureIdentity {
    /// The picture a video config describes, named as far as this end can name it.
    ///
    /// The catalogue is the only thing that says what a source is, so it is also the only source of
    /// "can this one change size on its own". A source with no catalogue entry is left unknown.
    public static func forStream(
        _ config: VideoStreamConfig,
        catalog: CaptureCatalog?,
        // The source itself where the caller has it, which is the one case the catalogue cannot
        // answer for. Optional so callers with only a config and a catalogue need not invent one.
        source: CaptureSource? = nil
    ) -> PictureIdentity {
        let descriptor = catalog?.all.first { $0.id == config.sourceID }

        // A mosaic is known without the catalogue, because this end built it: it has no row there and
        // never will. Left to the descriptor lookup below it would take the unknown answer, which
        // reads as a window, and a window keeps its magnification across a resize.
        let movesOnItsOwn = source?.stableID == config.sourceID && source?.isMosaic == true
            ? false
            : descriptor?.source.contentMovesOnItsOwn ?? true

        return PictureIdentity(
            sourceID: config.sourceID,
            pixelSize: CGSize(width: config.pixelWidth, height: config.pixelHeight),
            contentMovesOnItsOwn: movesOnItsOwn
        )
    }
}
