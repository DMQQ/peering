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

    /// Where each tile sits, in reading order, all of them given the same room.
    public static func rects(count: Int) -> [NormalizedRect] {
        rects(weights: Array(repeating: 1, count: count))
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
    public static func rects(weights: [Int]) -> [NormalizedRect] {
        let weights = weights.map { max($0, 1) }
        let count = weights.count
        guard count > 0 else { return [] }

        // **Every pixel of the canvas belongs to exactly one tile**, with no gaps to hit-test and
        // nothing to clamp, which is what keeps the rectangles honest under any weights at all.
        // A row takes its tiles' combined share of the height, and inside a row each tile takes
        // its own share of the width.
        //
        // The rows are the reading-order rows of the even grid, so a weight never reorders
        // anything: the shape of the arrangement changes and the arrangement does not. A row that
        // is not full is therefore shorter rather than padded, and the tiles in it share its
        // width between them — so five tiles are three across the top and two wider ones under
        // them, with no empty quarter of the picture for a tap to land on and do nothing.
        let columns = columns(for: count)
        let rowCount = Int((Double(count) / Double(columns)).rounded(.up))
        let rows: [[Int]] = (0..<rowCount).map { row in
            let start = row * columns
            return Array(start..<min(start + columns, count))
        }
        let total = Double(weights.reduce(0, +))

        var rects: [NormalizedRect] = []
        var y = 0.0
        for row in rows {
            // A row's height is its tiles' share of the whole, and within the row each tile takes
            // its share of the width. Slice and dice: every pixel of the canvas belongs to
            // exactly one tile, with no gap to hit-test and nothing to clamp.
            let rowWeight = Double(row.reduce(0) { $0 + weights[$1] })
            let height = rowWeight / total
            var x = 0.0
            for index in row {
                let width = Double(weights[index]) / rowWeight
                rects.append(NormalizedRect(x: x, y: y, width: width, height: height))
                x += width
            }
            y += height
        }
        return rects
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
        layout(
            choices: sources.map { MosaicChoice(source: $0) },
            viewport: viewport,
            frameRate: frameRate
        )
    }

    /// The same, for an arrangement whose tiles are not all the same size.
    public static func layout(
        choices: [MosaicChoice],
        viewport: CGSize,
        frameRate: Int = MosaicGrid.defaultFrameRate
    ) -> MosaicLayout? {
        let rects = rects(weights: choices.map(\.weight))
        let tiles = zip(choices, rects).map { MosaicTile(source: $0.source, rect: $1) }
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
