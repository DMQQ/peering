import CoreGraphics
import RemoteCore

/// What a picture is multiplied by on its way to the screen, over and above the user's zoom.
///
/// One number for two asks: the user's Fill, and the margin the chrome keeps when the rails are over
/// the picture's edges. Every rectangle in this app, a tile, the cursor, the tap that resolves to a
/// tile, is measured against the rectangle the pixels are actually drawn in.
///
/// A size rather than a number, because Fill scales whatever is on screen, so an arrangement's canvas
/// and one of its windows fill differently, and a movement aimed at the wrong fill overshoots and
/// then corrects itself.
public struct PictureScale: Equatable, Sendable {
    /// Whether the user has asked for the picture to reach the screen's edges.
    public let scalesToFill: Bool
    /// How much of the screen the chrome keeps to itself, each side. Zero when it keeps none.
    public let inset: CGFloat

    public init(scalesToFill: Bool, inset: CGFloat) {
        self.scalesToFill = scalesToFill
        self.inset = max(0, inset)
    }

    /// The scale a picture of this shape is drawn at, at the user's own zoom of 1.
    ///
    /// A picture of no size is drawn at 1, which is the case for the first frames of a session.
    public func base(pixelSize: CGSize, in bounds: CGSize) -> CGFloat {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return 1 }
        guard scalesToFill else { return 1 - inset * 2 }

        let rect = CanvasGeometry.videoRect(bounds: bounds, pixelSize: pixelSize)
        guard rect.width > 0, rect.height > 0 else { return 1 }
        return max(bounds.width / rect.width, bounds.height / rect.height)
    }

    /// The same scale, about the middle of the screen, applied to a rectangle.
    ///
    /// The second half of ``base(pixelSize:in:)``: a rectangle scaled about a different point than
    /// the picture it belongs to does not move with it.
    public func scaled(_ rect: CGRect, in bounds: CGSize, by scale: CGFloat) -> CGRect {
        let centre = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        return CGRect(
            x: centre.x + (rect.minX - centre.x) * scale,
            y: centre.y + (rect.minY - centre.y) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }
}

/// The movement between an arrangement and one of its windows, in both directions.
///
/// The picture moves, and nothing is drawn over it: every tile is a fraction of the one canvas the
/// Mac composited, so scaling that picture until the tile's window is the screen is the window
/// growing to fill it, with the other tiles leaving the edges on their own.
///
/// Both ends of the movement are the window's own rectangle, where it sits inside its tile now and
/// where it sits when it is the whole picture. The two have the same shape, so a straight scale takes
/// one to the other, and when the stream arrives the picture sharpens where it already is and the
/// reset that follows a source switch lands on the same rectangle the movement stopped at. Moving
/// the tile instead would put the window somewhere it never is, since a window is letterboxed inside
/// its tile; see ``MosaicTileFit/windowRect(sourceSize:in:)``.
///
/// `nil` is "there is nothing to move between", and every caller answers it the same way: the switch
/// still happens and only the movement is skipped.
public enum MosaicZoom {
    /// The zoom and the pan that turn one tile of the arrangement into that window on its own.
    ///
    /// The picture is drawn at ``PictureScale/base(pixelSize:in:)`` times the number stored in
    /// `zoom`, and the two pictures have different base scales in Fill, so the target is turned back
    /// into a stored zoom against the base on screen now, while the rectangle it aims at is built
    /// from the base the incoming picture will be drawn at. Aiming at the outgoing base lands the
    /// movement a fill-factor away from where the picture lands.
    ///
    /// `effectiveZoom` and `pan` are the state on screen, the user's zoom times that base (see
    /// ``PictureScale``), because the mapping is applied to what the picture is drawn at.
    public static func opening(
        layout: MosaicLayout,
        index: Int,
        sourceSize: CGSize?,
        bounds: CGSize,
        effectiveZoom: CGFloat,
        pan: CGSize,
        scale: PictureScale
    ) -> (zoom: CGFloat, pan: CGSize)? {
        guard bounds.width > 0, bounds.height > 0,
              layout.tiles.indices.contains(index),
              // No size, no movement. A source the catalogue cannot describe has no rectangle
              // inside it to aim at, and guessing, which is what asking `videoRect` for a size of
              // `nil` does, makes the destination the whole screen and the picture zooms until the
              // tile covers it: the overshoot this function exists to avoid.
              let sourceSize, sourceSize.width > 0, sourceSize.height > 0,
              effectiveZoom > 0
        else { return nil }

        let pictureSize = layout.canvas
        // Where the tile is on screen now, and where the window inside it is, both measured through
        // the arrangement's own canvas: the tile borders, the tap that opened this and the movement
        // are one rectangle, and it is a rectangle of the arrangement.
        guard let tile = CanvasGeometry.rect(
            normalized: layout.tiles[index].rect,
            bounds: bounds, pixelSize: pictureSize,
            zoom: effectiveZoom, pan: pan
        ), let window = MosaicTileFit.windowRect(sourceSize: sourceSize, in: tile)
        else { return nil }

        // Where the window will sit when it is the picture, in the state the reset after the switch
        // puts the view in: its own fit on this screen, at the incoming stream's base.
        let incoming = scale.base(pixelSize: sourceSize, in: bounds)
        let destination = scale.scaled(
            CanvasGeometry.videoRect(bounds: bounds, pixelSize: sourceSize),
            in: bounds,
            by: incoming
        )
        guard destination.width > 0, destination.height > 0 else { return nil }

        guard let target = CanvasGeometry.transform(
            of: window, mappingTo: destination,
            bounds: bounds, zoom: effectiveZoom, pan: pan
        ) else { return nil }

        let current = scale.base(pixelSize: pictureSize, in: bounds)
        guard current > 0 else { return nil }
        return (target.zoom / current, target.pan)
    }

    /// The zoom and the pan that draw a rectangle of a picture on a given rectangle of the screen.
    ///
    /// What makes a picture that arrives mid-movement look continuous: a stream the Mac builds faster
    /// than the movement takes would otherwise be drawn at the arrangement's zoom, two or three times
    /// too big. Instead the part the movement has been carrying is put where that part is on screen
    /// at this instant, so the switch is only the pixels changing.
    ///
    /// `anchor` is that part, as a fraction of `pixelSize`: the whole picture for a window arriving
    /// on its own, and a tile's rect for one arriving inside an arrangement.
    public static func placing(
        pixelSize: CGSize,
        anchor: NormalizedRect,
        at target: CGRect,
        bounds: CGSize,
        scale: PictureScale
    ) -> (zoom: CGFloat, pan: CGSize)? {
        guard bounds.width > 0, bounds.height > 0,
              pixelSize.width > 0, pixelSize.height > 0,
              target.width > 0, target.height > 0
        else { return nil }

        let base = scale.base(pixelSize: pixelSize, in: bounds)
        guard base > 0,
              let resting = CanvasGeometry.rect(
                  normalized: anchor, bounds: bounds, pixelSize: pixelSize,
                  zoom: 1, pan: .zero
              )
        else { return nil }

        // Where that piece of the picture is when the picture is at rest, and then the transform
        // that moves it onto the rectangle it has to occupy now.
        //
        // The resting rectangle is built at the picture's own base, so what comes back from
        // `transform` is already a multiple of that base, which is what the caller stores. Dividing
        // by the base as well is the same mistake twice: invisible at portrait's base of 1, and a
        // window a quarter too large under the chrome's 0.75 margin when held sideways.
        let drawn = scale.scaled(resting, in: bounds, by: base)
        guard let placed = CanvasGeometry.transform(
            of: drawn, mappingTo: target,
            bounds: bounds, zoom: 1, pan: .zero
        ), placed.zoom > 0
        else { return nil }

        return (placed.zoom, placed.pan)
    }

    /// The same movement backwards: the window shrinking into the tile it will hold.
    ///
    /// The way out is the way in, through the same pair of rectangles. The arrangement it aims at is
    /// the one being asked for rather than the one on screen, and the state it aims at is the one
    /// the Mac's answer will put the view in, so the movement ends exactly where the reset lands and
    /// the canvas appears around the window with nothing moving at all.
    ///
    /// `nil` when the window on screen is not one of the arrangement's tiles, which is a session with
    /// no arrangement to go back to; see ``MacSession/canReturnToMosaic``. `sourceID` is
    /// ``CaptureSource/stableID`` rather than the source, the thing a session keeps as "what is on
    /// screen", because the question is whether the picture belongs to this arrangement or was
    /// chosen after leaving it.
    public static func returning(
        layout: MosaicLayout,
        sourceID: String,
        sourceSize: CGSize?,
        bounds: CGSize,
        effectiveZoom: CGFloat,
        pan: CGSize,
        scale: PictureScale
    ) -> (zoom: CGFloat, pan: CGSize)? {
        guard bounds.width > 0, bounds.height > 0,
              layout.canvas.width > 0, layout.canvas.height > 0,
              let sourceSize, sourceSize.width > 0, sourceSize.height > 0,
              effectiveZoom > 0,
              let index = layout.tiles.firstIndex(where: { $0.source.stableID == sourceID })
        else { return nil }

        // Where the window is now: its own letterboxed rect on this screen, moved by whatever
        // zoom and pan are on it.
        let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        guard let current = CanvasGeometry.rect(
            normalized: full, bounds: bounds, pixelSize: sourceSize,
            zoom: effectiveZoom, pan: pan
        ) else { return nil }

        // Where it is going: inside its own tile of the arrangement that is coming, drawn at the
        // scale that canvas rests at.
        let incoming = scale.base(pixelSize: layout.canvas, in: bounds)
        guard incoming > 0,
              let tile = CanvasGeometry.rect(
                  normalized: layout.tiles[index].rect,
                  bounds: bounds, pixelSize: layout.canvas,
                  zoom: incoming, pan: .zero
              ),
              let destination = MosaicTileFit.windowRect(sourceSize: sourceSize, in: tile)
        else { return nil }

        guard let target = CanvasGeometry.transform(
            of: current, mappingTo: destination,
            bounds: bounds, zoom: effectiveZoom, pan: pan
        ) else { return nil }

        // Against the base the window is drawn at, which is the picture being left behind.
        let outgoing = scale.base(pixelSize: sourceSize, in: bounds)
        guard outgoing > 0 else { return nil }
        return (target.zoom / outgoing, target.pan)
    }
}
