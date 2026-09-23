import CoreGraphics

/// Where a window's own picture sits inside one tile of an arrangement, and how big that tile's
/// capture is built.
///
/// One rule with two readers, because the two ends have to agree about this exactly. The Mac
/// composites a tile by fitting the tile's captured surface into the tile's rectangle, and the
/// phone draws the tile's border, resolves the tap that opens it and works out the zoom that tap
/// travels with, all of them from "where is the window inside its tile". A second copy of the rule
/// at either end is a rectangle one of them is wrong about, and the way it shows is a zoom landing
/// somewhere the arriving stream then has to correct.
public enum MosaicTileFit {
    /// Where a source's own picture sits inside one tile: its own shape, as large as the tile
    /// allows, centred.
    ///
    /// The larger scale that fits, which is a scale up when the window is smaller than its slot.
    /// Both ends magnify to fill: the Mac when it draws the surface into the rectangle, the phone
    /// when it draws the border and aims the zoom.
    ///
    /// `nil` when either side is degenerate, rather than a rectangle of zeros to be drawn.
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
    /// The window's own shape, not the tile's: ScreenCaptureKit is handed a surface whose shape
    /// already matches the content, so it has nothing to crop or letterbox, and the picture it
    /// delivers is the window the phone assumes it is.
    ///
    /// Never larger than the source's own pixels: ``place`` magnifies the surface into the tile
    /// anyway, so the capture never needs to hold more pixels than the window has.
    ///
    /// Even on both axes: a `420v` surface is two planes and the chroma plane is half the size, so
    /// ScreenCaptureKit and VideoToolbox both want even dimensions, and an odd one is rounded
    /// somewhere inside the stack.
    ///
    /// Rounded to the nearest even rather than down: the phone computes this rectangle in points
    /// and the Mac in pixels, so this rounding is the only disagreement left.
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
