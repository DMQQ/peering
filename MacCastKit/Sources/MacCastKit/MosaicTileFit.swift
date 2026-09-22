import CoreGraphics

/// Where a window's own picture sits inside one tile of an arrangement, and how big that tile's
/// capture is built.
///
/// **One rule with two readers, because the two ends have to agree about this exactly.** The Mac
/// composites a tile by fitting the tile's captured surface into the tile's rectangle, and the
/// phone draws the tile's border, resolves the tap that opens it and works out the zoom that tap
/// travels with — all of them from "where is the window inside its tile". A second copy of the
/// rule at either end is a rectangle one of them is wrong about, and the way it shows is the zoom
/// landing somewhere the arriving stream then has to correct: a zoom in and a zoom back out, on
/// the one gesture in the app that is supposed to be explained by its own movement.
///
/// **It was not shared, and the hosts' half was not this rule.** A tile's surface used to be
/// sized by taking each axis of the tile separately and clamping it to the source's own size on
/// that axis, which produces a shape that is neither the tile's nor the window's: a 400×800
/// palette window in a 588×368 slot was captured at 400×368, so the Mac drew a window of one
/// shape inside a rectangle the phone believed held a window of another. The measured mismatch is
/// small for an arrangement of ordinary windows and large for anything unusual, and in both cases
/// the zoom aimed at a rectangle that was not the one on screen.
public enum MosaicTileFit {
    /// Where a source's own picture sits inside one tile: its own shape, as large as the tile
    /// allows, centred.
    ///
    /// **The larger scale that fits, which is a scale *up* when the window is smaller than its
    /// slot.** A tile is a window photographed into a rectangle that was chosen for it, and a
    /// small window that sat at its own pixel size in the corner of a large slot would be a tile
    /// nobody can read. Both ends magnify to fill: the Mac when it draws the surface into the
    /// rectangle, the phone when it draws the border and aims the zoom.
    ///
    /// `nil` when either side is degenerate, which is the caller's answer to "there is nothing to
    /// place" rather than a rectangle of zeros to be drawn.
    public static func windowRect(sourceSize: CGSize, in tile: CGRect) -> CGRect? {
        guard sourceSize.width > 0, sourceSize.height > 0,
              tile.width > 0, tile.height > 0
        else { return nil }

        let scale = min(tile.width / sourceSize.width, tile.height / sourceSize.height)
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(
            x: tile.midX - size.width / 2,
            y: tile.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The size a tile's own capture is configured at.
    ///
    /// **The window's own shape, not the tile's.** It is what makes the rest of the rule true:
    /// ScreenCaptureKit is handed a surface whose shape already matches the content, so it has
    /// nothing to crop and nothing to letterbox, and the picture it delivers is the window —
    /// which is also what the phone assumes when it works out where the window is. Asking for the
    /// tile's shape instead used to leave ScreenCaptureKit a choice about a window that did not
    /// fit it, and the answer was a crop the phone did not know about.
    ///
    /// **Never larger than the source's own pixels**, because a surface bigger than the thing
    /// being photographed is a window scaled up by the WindowServer for nobody: ``place``
    /// magnifies the surface into the tile anyway, so a small window fills its slot without the
    /// capture ever holding more pixels than the window has.
    ///
    /// **Even on both axes, and that is load-bearing.** A `420v` surface is two planes, and the
    /// chroma plane is half the size, so ScreenCaptureKit and VideoToolbox both want even
    /// dimensions — an odd one is rounded somewhere inside the stack, which leaves the client
    /// drawing a picture whose size is not the one the Mac thinks it built.
    ///
    /// **Rounded to the nearest even rather than down to it.** The two ends agree about this
    /// rectangle — the phone computes it in points, the Mac in pixels — and the only disagreement
    /// left is this rounding, so it is worth being half a pixel out rather than a whole one.
    public static func surface(sourceSize: CGSize, tilePixels: CGRect) -> CGSize? {
        guard let fitted = windowRect(sourceSize: sourceSize, in: tilePixels) else { return nil }

        func even(_ value: CGFloat) -> CGFloat {
            max(2, (value / 2).rounded() * 2)
        }
        return CGSize(
            width: even(min(fitted.width, sourceSize.width)),
            height: even(min(fitted.height, sourceSize.height))
        )
    }
}
