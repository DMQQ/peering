import CoreGraphics
import Foundation
import RemoteCore

/// Arranging tiles on the phone: how many fit, where they sit, and how big the canvas is.
///
/// **The phone decides and the Mac draws.** Nothing here knows what a Mac is: the layout is a
/// canvas size and a list of rectangles in it, which is exactly what travels on the wire, so the
/// whole arrangement can be worked out, hit-tested and unit-tested with no device attached. See
/// ``MosaicLayout`` for what the host does with it.
///
/// The rectangles are always a grid in this version. A freeform arrangement is a different
/// function of the same return type rather than a change to the wire, which is why the wire
/// carries rectangles rather than a tile count.
public enum MosaicGrid {
    /// The rate a mosaic is asked for unless the user says otherwise.
    ///
    /// **Lower than a single source on purpose.** A mosaic is N captures composited per frame, so
    /// its rate multiplies the Mac's work by N where a single source's does not; and what a
    /// mosaic is *for* is watching several things at once, which is the case that tolerates 15
    /// frames a second rather than the one that notices 60. Selecting a tile goes back to the
    /// ordinary path at the ordinary rate, which is where the sharpness and the smoothness are
    /// wanted anyway.
    public static let defaultFrameRate = 15

    /// The fewest columns that hold this many tiles.
    ///
    /// The square root, rounded up, so a 3×2 grid is what six tiles get on a landscape screen and
    /// four get a 2×2. Deliberately not a function of the canvas's aspect: a rule that changed
    /// with the phone's rotation would rearrange a layout nobody asked to rearrange.
    public static func columns(for count: Int) -> Int {
        guard count > 1 else { return 1 }
        var columns = 1
        while columns * columns < count { columns += 1 }
        return columns
    }

    /// Where each tile sits, in reading order.
    ///
    /// Every cell is the same size and the last row is left-aligned rather than stretched: five
    /// tiles are three across the top and two under them, with the gap at the end where a sixth
    /// would go. Stretching the remainder to fill the row would give those two a different shape
    /// from the three above them, which reads as a bug rather than as a decision.
    public static func rects(count: Int) -> [NormalizedRect] {
        guard count > 0 else { return [] }
        let columns = columns(for: count)
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        let width = 1.0 / Double(columns)
        let height = 1.0 / Double(rows)

        return (0..<count).map { index in
            NormalizedRect(
                x: Double(index % columns) * width,
                y: Double(index / columns) * height,
                width: width,
                height: height
            )
        }
    }

    /// The canvas pixel size to ask a Mac for, from the screen the mosaic is drawn on.
    ///
    /// **The screen's own pixels, so a tile is as sharp as the pixels it lands on.** Each tile
    /// gets a fraction of the canvas, so a canvas smaller than the display would make every tile
    /// soft before the encoder ever saw it; and the host trims a canvas that is larger than it
    /// will build. Both numbers are rounded to even here rather than left for the host, because
    /// the encoder rounds down to even and a client that asked for an odd canvas would have its
    /// rectangles measured against a picture a pixel narrower than the one it described.
    public static func canvas(for viewport: CGSize) -> CGSize {
        // The rounding is `floor then halve then floor`, not `divide by two and multiply back`:
        // in floating point those are not the same, and the shorter one leaves an odd number
        // odd. 1179 / 2 * 2 is 1179, which is the whole rule failing silently.
        func even(_ value: CGFloat) -> CGFloat {
            max(2, (value / 2).rounded(.down) * 2)
        }
        return CGSize(
            width: min(even(viewport.width), 2560),
            height: min(even(viewport.height), 1440)
        )
    }

    /// A whole layout: the sources the user picked, arranged on a canvas built for this screen.
    public static func layout(
        sources: [CaptureSource],
        viewport: CGSize,
        frameRate: Int = MosaicGrid.defaultFrameRate
    ) -> MosaicLayout? {
        let tiles = zip(sources, rects(count: sources.count)).map {
            MosaicTile(source: $0, rect: $1)
        }
        return MosaicLayout(
            canvas: canvas(for: viewport),
            tiles: tiles,
            frameRate: frameRate
        ).validated
    }

    /// Which tile a point on the picture lands in, or `nil` for a gap between them.
    ///
    /// **Before the canvas is clamped, not after.** ``NormalizedRect/contains(_:)`` is half-open
    /// on each far edge so the line between two tiles belongs to exactly one of them, and a point
    /// outside every rect is the gap rather than the nearest tile: a tap in the seam between two
    /// tiles that selected one of them would be a coin toss the user did not ask for.
    public static func tileIndex(at point: NormalizedPoint, in layout: MosaicLayout) -> Int? {
        layout.tiles.firstIndex { $0.rect.contains(point) }
    }
}
