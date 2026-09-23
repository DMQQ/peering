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
/// One thing the user asked for, before the arithmetic turns it into a rectangle.
///
/// **The intent, kept rather than the result.** A layout is rectangles in a canvas of a
/// particular shape, which is what the Mac needs and what a different phone or a rotation would
/// make stale; what the user actually chose is "these windows, in this order, with this one
/// bigger". Storing that and deriving the rectangles is one copy of the arrangement instead of
/// two that can disagree. See ``MacSession/mosaicChoices``.
public struct MosaicChoice: Codable, Equatable, Sendable {
    public var source: CaptureSource
    /// How much of the picture this one gets, relative to the others. 1 is "the same as
    /// everyone", and the control on screen steps between 1 and 3.
    public var weight: Int

    public init(source: CaptureSource, weight: Int = 1) {
        self.source = source
        self.weight = weight
    }

    /// The weights the size control steps through, so the button and the arithmetic cannot
    /// disagree about how big a tile may get.
    public static let maximumWeight = 3
    public static let minimumWeight = 1
}

/// The arrangements this phone has put together, remembered per Mac.
///
/// **Kept as the choices rather than as the rectangles**, which is the whole reason this can be
/// restored at all: a saved layout would describe windows at positions in a canvas of the shape
/// this phone had when it was saved, and the phone in a different orientation, or a mosaic asked
/// for after an update that changed the padding, would draw the wrong picture from it. What the
/// user chose is "these windows, in this order, with this one bigger", and that survives all of
/// it. See ``MosaicChoice``.
///
/// A source that has gone is dropped on the way back rather than refusing the whole arrangement:
/// a window is closed, an application is quit, and the other five were the point. See
/// ``MosaicArrangement/restored(into:)``.
public enum MosaicArrangementStore {
    private static let key = "Peering.mosaicArrangements"

    /// Every Mac's arrangement, by the Mac's own id.
    ///
    /// One dictionary rather than a key per Mac, because a key built from an id could collide
    /// with anything else in the defaults and because the ids are not known until a Mac answers.
    private static func arrangements() -> [String: [MosaicChoice]] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode([String: [MosaicChoice]].self, from: data)
        else { return [:] }
        return stored
    }

    /// What is remembered for one Mac, or nothing when there is no arrangement.
    public static func load(hostID: String) -> [MosaicChoice] {
        arrangements()[hostID] ?? []
    }

    public static func save(_ choices: [MosaicChoice], hostID: String) {
        var stored = arrangements()
        if choices.count > 1 {
            stored[hostID] = choices
        } else {
            // **Emptying it is how an arrangement is forgotten**, rather than a separate call
            // that could be left out: a session with one tile is a session with no mosaic in it,
            // and the next connection to that Mac should not open on a canvas holding one
            // window.
            stored.removeValue(forKey: hostID)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

public enum MosaicArrangement {
    /// The remembered arrangement, thinned to the sources this Mac still has.
    ///
    /// **The catalogue is the filter.** A window ID or a process ID outlives neither a restart
    /// nor a quit, so what comes back is a list of sources that may or may not still exist, and
    /// the only thing in a session that says which is the catalogue the Mac has just sent. Fewer
    /// than two survivors is not a mosaic, so that is nothing rather than one.
    public static func restored(_ choices: [MosaicChoice], into catalog: CaptureCatalog?) -> [MosaicChoice] {
        guard let catalog else { return [] }
        let living = choices.filter { catalog.descriptor(for: $0.source) != nil }
        return living.count > 1 ? living : []
    }
}

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

    /// The shape a tile is drawn at when nothing in the arrangement says otherwise.
    ///
    /// A Mac's window, near enough. Sixteen by ten covers the great majority of them, and it is
    /// the aspect the canvas falls back to when the catalogue cannot describe what is in the
    /// arrangement — a source that has gone, or a mosaic put together before any catalogue
    /// arrived. See ``MosaicGrid/canvas(columns:tiles:tileAspect:viewport:)``.
    public static let windowAspect: Double = 1.6

    /// The fewest columns that hold this many tiles, on a phone held this way.
    ///
    /// **The square root, rounded to the side the phone has room for.** A grid of tiles is as
    /// square as it can be, and which way the rounding goes is the phone's business: held
    /// sideways it has the width for another column, and held up it has the height for another row
    /// instead.
    ///
    /// So a phone held up rounds *down*: six tiles are two across and three down, where rounding
    /// up would be three across and two down. The canvas follows the arrangement rather than the
    /// screen — see ``canvas(columns:tiles:tileAspect:viewport:)`` — so this is the whole of what
    /// the orientation decides, and the tiles come out the shape of windows either way.
    public static func columns(for count: Int, portrait: Bool) -> Int {
        guard count > 1 else { return 1 }
        let root = Double(count).squareRoot()
        let rounded = portrait ? root.rounded(.down) : root.rounded(.up)
        return max(1, min(Int(rounded), count))
    }

    /// Where each tile sits, in reading order, all of them given the same room.
    public static func rects(count: Int, portrait: Bool) -> [NormalizedRect] {
        rects(weights: Array(repeating: 1, count: count), portrait: portrait)
    }

    /// The same, where each tile may ask for more room than its neighbours.
    ///
    /// **A weight rather than a size**, because a size is what the canvas happens to give it: the
    /// user says "this one matters more" and the arithmetic decides what that means on a canvas of
    /// this shape, with this many tiles beside it. Doubling a tile's weight doubles the room it
    /// gets, both along its row and in the height of that row, and every other tile keeps its own
    /// share of what is left — which is what makes the control understandable without a number
    /// appearing anywhere on screen.
    ///
    /// Equal weights are the even grid above, exactly, and that is asserted rather than assumed:
    /// a user who has not touched the size control gets the layout this feature shipped with.
    public static func rects(weights: [Int], portrait: Bool) -> [NormalizedRect] {
        let weights = weights.map { max($0, 1) }
        let count = weights.count
        guard count > 0 else { return [] }

        // **Every tile is the same size, which is what a grid is.** A row that is not full used to
        // share its width between its tiles, so five tiles were three across the top and two
        // wider ones under them. That left no pixel of the canvas unclaimed, which was the reason
        // for it, and it made the last row's tiles larger than every other: an arrangement whose
        // tiles are different sizes reads as a mistake rather than a layout.
        //
        // A short row is now the same size as the rest and centred, so what is left over is the
        // same margin on both sides rather than one tile's worth of background in a corner. It is
        // a margin a tap can land on and do nothing, which is the cost of this and was the reason
        // the other arrangement existed.
        //
        // **The weights are read and no longer used**, which is the honest state of them: nothing
        // on the phone sets one any more — see ``MosaicChoice/weight`` — and a size control cannot
        // coexist with a grid whose whole point is that every cell is the same. They are left in
        // the signature rather than removed because an arrangement that has been stored and
        // restored still carries them, and dropping the parameter would drop that data with it.
        _ = weights

        let columns = columns(for: count, portrait: portrait)
        let rowCount = Int((Double(count) / Double(columns)).rounded(.up))
        let cell = 1.0 / Double(columns)
        let height = 1.0 / Double(rowCount)

        var rects: [NormalizedRect] = []
        for index in 0..<count {
            let row = index / columns
            let column = index % columns
            // A short row is centred: the same tile as every other, with the leftover split
            // evenly either side rather than collected at one end.
            let inRow = min(columns, count - row * columns)
            let margin = (1 - cell * Double(inRow)) / 2
            rects.append(NormalizedRect(
                x: margin + cell * Double(column),
                y: height * Double(row),
                width: cell,
                height: height
            ))
        }
        return rects
    }

    /// The canvas to ask a Mac for: the shape of the arrangement, at the screen's own pixels.
    ///
    /// **The shape of the arrangement and not the shape of the phone**, which is the third answer
    /// to this question and the one that holds.
    ///
    /// A canvas is divided into a grid, so the canvas's aspect *is* the shape of every tile in it.
    /// Take the phone's shape and the tiles inherit it: held up, that is 0.56 to 1, and a window
    /// photographed into a tile like that is a band across the middle with black above and below
    /// it — 45% of every tile spent on nothing, on all six of them, and all of it captured,
    /// composited, encoded and paid for over the air. Held sideways it happens to look right,
    /// because a landscape phone and a landscape window are the same shape by luck.
    ///
    /// So the tiles are given the shape they want — the arrangement's own, from what its windows
    /// actually are, see ``MosaicGrid/windowAspect`` — and the canvas is built to whatever shape
    /// that makes: two columns of windows are 3.2 to 1, two columns by three rows of them are
    /// 1.07 to 1. The phone's orientation still decides the *grid*: see
    /// ``columns(for:portrait:)``, which gives a phone held up fewer columns and the same window
    /// size, and a phone held sideways a wider arrangement that fills its screen exactly.
    ///
    /// **The size is the screen's, though, and that half is unchanged in spirit.** The canvas is
    /// the largest picture of its shape that the screen could show at the screen's own pixels —
    /// whichever axis the fit would bind on gets the screen's full measurement — so a tile is
    /// never softer than the pixels it lands on, and never carries more than those either. The
    /// area cap is applied after, by scaling both sides together, so a shape a Mac will not build
    /// comes back smaller rather than reshaped.
    ///
    /// Both numbers are rounded to even here rather than left for the host, because the encoder
    /// rounds down to even and a client that asked for an odd canvas would have its rectangles
    /// measured against a picture a pixel narrower than the one it described.
    ///
    /// **Turning the phone therefore re-asks for the arrangement**, and the Mac tears down and
    /// rebuilds every tile's stream: a short stop in the picture, once, at the moment the user
    /// turned the phone. That is the price of a grid that follows the phone at all, and the fix
    /// for the stop is on the Mac — keeping the tile streams when only the rectangles change.
    /// - Parameters:
    ///   - columns: how many tiles are across, from ``columns(for:portrait:)``.
    ///   - tiles: how many there are in total, which is not `columns × rows`: a mosaic of eight is
    ///     three across and three down, and the row that is not full shares its own width rather
    ///     than leaving a slot empty. A tile is `1/columns` of the width and `columns/tiles` of the
    ///     height, and the canvas has to be the shape that makes those two a window — which is
    ///     why this takes the count and not the row count.
    public static func canvas(
        columns: Int,
        tiles: Int,
        tileAspect: Double,
        viewport: CGSize
    ) -> CGSize {
        let columns = max(columns, 1)
        let tiles = max(tiles, 1)
        // **From the grid's rows, not from the number of tiles.** A cell's shape is the canvas's
        // aspect divided by the shape of the grid, and the grid is `columns` wide and
        // `ceil(tiles/columns)` tall whether or not its last row is full. Counted in tiles
        // instead, a short row made the canvas wider than the cells it was cut into — which was
        // right while that row shared its width between its tiles and a cell there really was
        // wider, and is wrong now that every cell is the same. For a full grid the two are the
        // same number, which is why this was never visible. See ``rects(count:portrait:)``.
        let rows = (Double(tiles) / Double(columns)).rounded(.up)
        let aspect = min(max(Double(columns) / rows * tileAspect, 0.05), 20)

        // Whichever axis the fit would bind on is the one that gets the screen's full size: a
        // canvas wider than the screen is drawn as wide as the screen, and one taller than the
        // screen is drawn as tall as it.
        var width = min(viewport.width, viewport.height * CGFloat(aspect))
        var height = width / CGFloat(aspect)

        let budget = CGFloat(MosaicLayout.maximumCanvasPixels)
        let area = width * height
        if area > budget {
            let scale = (budget / area).squareRoot()
            width *= scale
            height *= scale
        }

        // The rounding is `floor then halve then floor`, not `divide by two and multiply back`:
        // in floating point those are not the same, and the shorter one leaves an odd number
        // odd. 1179 / 2 * 2 is 1179, which is the whole rule failing silently.
        func even(_ value: CGFloat) -> CGFloat {
            max(2, (value / 2).rounded(.down) * 2)
        }
        return CGSize(width: even(width), height: even(height))
    }

    /// A whole layout: the sources the user picked, arranged on a canvas built for this screen.
    public static func layout(
        sources: [CaptureSource],
        viewport: CGSize,
        frameRate: Int = MosaicGrid.defaultFrameRate
    ) -> MosaicLayout? {
        layout(
            choices: sources.map { MosaicChoice(source: $0) },
            viewport: viewport,
            frameRate: frameRate
        )
    }

    /// The same, for an arrangement whose tiles are not all the same size.
    ///
    /// **The order is the whole of it**: the phone's orientation says how many columns, the grid
    /// says how many rows that makes, the number of tiles and their shape say what the canvas is,
    /// and the canvas is what the rectangles are fractions of.
    ///
    /// `tileAspect` is how wide the things in the arrangement are — the caller's business rather
    /// than this function's, because it is a fact about the sources and this is arithmetic about
    /// rectangles. See ``MosaicGrid/windowAspect`` for where a caller that does not know starts.
    public static func layout(
        choices: [MosaicChoice],
        viewport: CGSize,
        tileAspect: Double = MosaicGrid.windowAspect,
        frameRate: Int = MosaicGrid.defaultFrameRate
    ) -> MosaicLayout? {
        let portrait = viewport.height > viewport.width
        let columns = columns(for: choices.count, portrait: portrait)
        let rects = rects(weights: choices.map(\.weight), portrait: portrait)
        let tiles = zip(choices, rects).map { MosaicTile(source: $0.source, rect: $1) }
        return MosaicLayout(
            canvas: canvas(columns: columns, tiles: choices.count, tileAspect: tileAspect, viewport: viewport),
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
