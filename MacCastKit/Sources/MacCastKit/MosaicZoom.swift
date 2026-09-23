import CoreGraphics
import RemoteCore

/// What a picture is multiplied by on its way to the screen, over and above the user's zoom.
///
/// **One number for two different asks, because both of them are the same ask.** Fill is the user
/// saying the picture's edges should be the screen's; the chrome's margin is the app saying they
/// should not be, because held sideways the rails are over them. Either way the answer is a
/// scale, and every rectangle in this app — a tile, the cursor, the tap that resolves to a tile —
/// is measured against the rectangle the pixels are actually drawn in.
///
/// It is a value with a *size* rather than a number because the answer is not the same for every
/// picture: Fill scales whatever is on screen to the screen, so the canvas of an arrangement and
/// one of its windows have different fills. That distinction is the whole reason this type exists
/// — a movement that aims at the fill of the picture it is *leaving* finishes somewhere the
/// picture it is *arriving at* does not agree with, which is a zoom that overshoots and then
/// corrects itself.
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
    /// **A picture of no size is drawn at 1**, which is the answer for the first frames of a
    /// session: nothing is on screen yet, so there is no rectangle to fill and no shape to keep.
    public func base(pixelSize: CGSize, in bounds: CGSize) -> CGFloat {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return 1 }
        guard scalesToFill else { return 1 - inset * 2 }

        let rect = CanvasGeometry.videoRect(bounds: bounds, pixelSize: pixelSize)
        guard rect.width > 0, rect.height > 0 else { return 1 }
        return max(bounds.width / rect.width, bounds.height / rect.height)
    }

    /// The same scale, about the middle of the screen, applied to a rectangle.
    ///
    /// Kept here rather than written out at each caller because it is the second half of
    /// ``base(pixelSize:in:)``: a rectangle scaled about a different point than the picture it
    /// belongs to is a rectangle that does not move with it.
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
/// **The picture moves, and nothing is drawn over it.** Every tile is a fraction of one picture —
/// the canvas the Mac composited — so scaling that picture until the tile's window is the screen
/// *is* the window growing to fill it, with the other tiles leaving the edges on their own. The
/// alternative was a black scrim with a hole in it, which could not work: the hole was a `Path`,
/// a `Path` has no animatable data, and even animated the window inside the tile was not the
/// thing growing.
///
/// **The movement is aimed at where the window will already be.** The Mac takes a moment to build
/// the new stream, and until it arrives the last canvas frame is what is on screen — at the zoom
/// that was asked for, which is what the user is looking at. So both ends of the movement are the
/// *window's* rectangle: where it sits inside its tile now, and where it sits when it is the
/// whole picture. The two have the same shape, so the movement between them is a straight scale
/// about a point, and when the stream arrives the geometry does not change at all: the picture
/// sharpens where it already is, and the reset that every source switch gets lands on the same
/// rectangle the movement stopped at.
///
/// **A tile is not the thing being moved, and this is the correction that cost two attempts.** A
/// window is letterboxed inside its tile, so moving *the tile* to the screen moves the window
/// somewhere it will never be, and the picture jumps when the real stream arrives at the fit.
/// See ``MosaicTileFit/windowRect(sourceSize:in:)`` for where the window actually is, which is
/// the rectangle both of these functions measure from.
///
/// `nil` is always "there is nothing to move between" — no arrangement, no such tile, no size for
/// the source, a screen of no size — and every caller answers it the same way: the switch still
/// happens, and only the movement is skipped.
public enum MosaicZoom {
    /// The zoom and the pan that turn one tile of the arrangement into that window on its own.
    ///
    /// **The division at the end is this file's, and it is the whole of what was wrong with the
    /// movement.** The picture is drawn at ``PictureScale/base(pixelSize:in:)`` times the number
    /// stored in `zoom`, and the two pictures have different base scales in Fill — so a target
    /// expressed as a *drawn* scale has to be turned back into a stored one against the base that
    /// is on screen **now**, while the rectangle it aims at has to be built from the base the
    /// incoming picture will be drawn at. Aiming at the outgoing base instead is a movement that
    /// ends a fill-factor away from where the picture lands: at Fill the canvas's fill is 2.3 and
    /// its window's is 3.3, so the window is drawn a third too small for the whole of the
    /// movement and then has to grow again when the stream arrives.
    ///
    /// `effectiveZoom` and `pan` are the state on screen, which is the user's zoom *times* that
    /// base — see ``PictureScale`` — because the mapping is applied to what the picture is
    /// actually drawn at.
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
              // **No size, no movement.** A source the catalogue cannot describe is a tile with a
              // card in it or a window that has gone, and there is no rectangle inside it to aim
              // at. Guessed at — which is what asking `videoRect` for a size of `nil` does — the
              // destination becomes the *whole screen*, so the picture zooms until the tile
              // covers it and the reset then pulls it back: the largest version of exactly the
              // overshoot this function exists to avoid.
              let sourceSize, sourceSize.width > 0, sourceSize.height > 0,
              effectiveZoom > 0
        else { return nil }

        let pictureSize = layout.canvas
        // Where the tile is on screen now, and where the window inside it is. Both through the
        // arrangement's own canvas rather than through whatever is on screen: the tile borders,
        // the tap that opened this and the movement are one rectangle, and it is a rectangle of
        // the arrangement.
        guard let tile = CanvasGeometry.rect(
            normalized: layout.tiles[index].rect,
            bounds: bounds, pixelSize: pictureSize,
            zoom: effectiveZoom, pan: pan
        ), let window = MosaicTileFit.windowRect(sourceSize: sourceSize, in: tile)
        else { return nil }

        // Where the window will sit when it is the picture, in the state the reset after the
        // switch puts the view in: its own fit on this screen, at the *incoming* stream's base.
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

    /// The zoom and the pan that draw a rectangle *of* a picture on a given rectangle of the screen.
    ///
    /// **What makes a picture that arrives in the middle of a movement continuous.** A movement is
    /// a journey between two rectangles of one window, and it can be overtaken: the Mac builds the
    /// new stream in less time than the movement takes, so the picture changes part-way through.
    /// Read through the state the movement has reached, a stream that is now the *whole* picture is
    /// drawn at the arrangement's zoom — two or three times too big, in the middle of a gesture
    /// whose point was to end at the fit. Corrected by a second movement, that is "it zooms in and
    /// then zooms out to fit the window".
    ///
    /// The answer is to say where the arriving picture goes rather than to let the old state say
    /// it: the part of it that the movement has been carrying — all of a window opened from a tile,
    /// the tile's window when an arrangement is coming back — is put exactly where that part is on
    /// screen at this instant. The switch is then only the pixels changing, and the movement that
    /// follows has the rest of its journey to finish.
    ///
    /// `anchor` is that part, as a fraction of `pixelSize`. It is the whole picture for a window
    /// arriving on its own, and a fraction of it for a window arriving inside an arrangement.
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
        // **The base is already in the resting rectangle, and the answer is not divided by it.**
        // The starting state handed to `transform` is zoom 1 and no pan, which is the picture at
        // its own base — so what comes back is a multiple of that base, which is exactly what the
        // caller stores. Dividing it by the base as well is the same mistake twice, and it is
        // invisible until the base is not 1: portrait draws the picture at 1, so the division did
        // nothing, and a phone held sideways carries the chrome's margin at 0.75, where a window
        // opened from a tile landed a quarter too large and then shrank into place.
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
    /// **The way out of an arrangement is the way in, through the same pair of rectangles.** A
    /// movement that describes what a tap did and then nothing on the way back would be the app
    /// having two different ideas of what the two states are.
    ///
    /// The arrangement it aims at is the one being *asked for* rather than the one on screen —
    /// the picture is a single window, and what is coming is the canvas built around it — and the
    /// state it aims at is the one the Mac's answer will put the view in, which is what
    /// ``PictureScale/inset`` and ``PictureScale/scalesToFill`` describe for the canvas. That is
    /// the trick of the whole thing: the movement ends exactly where the reset lands, so the
    /// canvas appears around the window with nothing moving at all.
    ///
    /// `nil` when the window on screen is not one of the arrangement's tiles — a source chosen
    /// after the mosaic was left, which is a session with no arrangement to go back to. See
    /// ``MacSession/canReturnToMosaic``.
    /// `sourceID` is ``CaptureSource/stableID`` rather than the source itself: it is what a
    /// session keeps as "what is on screen" — see ``SessionModel/activeSourceID`` — and the whole
    /// question here is whether the picture belongs to this arrangement or was chosen after
    /// leaving it.
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

        // Against the base the *window* is drawn at, which is the picture being left behind.
        let outgoing = scale.base(pixelSize: sourceSize, in: bounds)
        guard outgoing > 0 else { return nil }
        return (target.zoom / outgoing, target.pan)
    }
}
