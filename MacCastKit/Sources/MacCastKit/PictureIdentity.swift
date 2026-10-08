import CoreGraphics
import RemoteCore

public struct PictureIdentity: Equatable {
    public init(sourceID: String?, pixelSize: CGSize, contentMovesOnItsOwn: Bool) {
        self.sourceID = sourceID
        self.pixelSize = pixelSize
        self.contentMovesOnItsOwn = contentMovesOnItsOwn
    }

    /// The capture source this phone believes the picture belongs to.
    public let sourceID: String?
    public let pixelSize: CGSize
    /// Whether this source's size changes without the source changing: this is
    /// ``CaptureSource/contentMovesOnItsOwn``, carried rather than looked up again because the
    /// picture and the catalogue it was named from are not read at the same moment.
    public let contentMovesOnItsOwn: Bool

    public enum Change: Equatable {
        case unchanged
        case resized
        case replaced
    }

    public func change(to next: PictureIdentity) -> Change {
        // The names are compared only when both ends have one: a picture described before the
        // catalogue arrived is nameless, and the name catching up with it is not a source change.
        if let mine = sourceID, let theirs = next.sourceID, mine != theirs { return .replaced }
        if pixelSize == next.pixelSize { return .unchanged }

        return contentMovesOnItsOwn ? .resized : .replaced
    }
}

extension PictureIdentity {
    /// The picture a video config describes, named as far as this end can name it.
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
