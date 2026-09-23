import CoreGraphics
import Foundation
import RemoteCore

/// Arranging tiles on the phone: how many fit, where they sit, and how big the canvas is.
///
/// The phone decides and the Mac draws: a layout is a canvas size and a list of rectangles, which
/// is what travels on the wire. See ``MosaicLayout`` for what the host does with it.
///
/// The rectangles are always a grid in this version: a freeform arrangement is a different function
/// of the same return type rather than a change to the wire, which is why the wire carries
/// rectangles rather than a tile count.
/// One thing the user asked for, before the arithmetic turns it into a rectangle.
///
/// The choice is stored rather than the rectangles it produces, which is what survives a rotation
/// or a change to the padding. See ``MacSession/mosaicChoices``.
public struct MosaicChoice: Codable, Equatable, Sendable {
    public var source: CaptureSource
    /// How much of the picture this one gets, relative to the others; 1 is the same as everyone.
    public var weight: Int

    public init(source: CaptureSource, weight: Int = 1) {
        self.source = source
        self.weight = weight
    }

    /// The weights the size control steps between, so the button and the arithmetic cannot disagree.
    public static let maximumWeight = 3
    public static let minimumWeight = 1
}

/// The arrangements this phone has put together, remembered per Mac.
///
/// Kept as the choices rather than as the rectangles, which is what survives a rotation or a
/// changed padding. A source that has gone is dropped on the way back rather than refusing the
/// whole arrangement; see ``MosaicArrangement/restored(into:)`` and ``MosaicChoice``.
public enum MosaicArrangementStore {
    private static let key = "Peering.mosaicArrangements"

    /// Every Mac's arrangement, by the Mac's own id.
    ///
    /// One dictionary rather than a key per Mac: a key built from an id could collide with anything
    /// else in the defaults.
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
            // Emptying it is how an arrangement is forgotten, rather than a separate call that
            // could be left out: one tile is not a mosaic, and the next connection to that Mac
            // should not open on a canvas holding one window.
            stored.removeValue(forKey: hostID)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

public enum MosaicArrangement {
    /// The remembered arrangement, thinned to the sources this Mac still has.
    ///
    /// A window ID or a process ID outlives neither a restart nor a quit, so the catalogue the Mac
    /// has just sent is the only thing that can say which are still there; fewer than two survivors
    /// is not a mosaic, so that is nothing rather than one.
    public static func restored(_ choices: [MosaicChoice], into catalog: CaptureCatalog?) -> [MosaicChoice] {
        guard let catalog else { return [] }
        let living = choices.filter { catalog.descriptor(for: $0.source) != nil }
        return living.count > 1 ? living : []
    }
}

public enum MosaicGrid {
    /// The rate a mosaic is asked for unless the user says otherwise.
    ///
    /// Lower than a single source on purpose: a mosaic is N captures composited per frame, so its
    /// rate multiplies the Mac's work by N. Selecting a tile goes back to the ordinary rate.
    public static let defaultFrameRate = 15

    /// The shape a tile is drawn at when nothing in the arrangement says otherwise.
    ///
    /// A Mac's window, near enough, and the canvas's fallback when the catalogue cannot describe
    /// what is in the arrangement.
    public static let windowAspect: Double = 1.6

    /// The fewest columns that hold this many tiles, on a phone held this way.
    ///
    /// The square root of the count, rounded to the side the phone has room for: held sideways it has
    /// the width for another column, held up the height for another row. The canvas follows the
    /// arrangement rather than the screen, so this is all the orientation decides.
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
    /// A weight rather than a size: the user says "this one matters more" and the arithmetic decides
    /// what that means on a canvas of this shape. Equal weights are the even grid above, exactly.
    public static func rects(weights: [Int], portrait: Bool) -> [NormalizedRect] {
        let weights = weights.map { max($0, 1) }
        let count = weights.count
        guard count > 0 else { return [] }

        // Every tile is the same size, which is what a grid is: a short row holds tiles the same
        // size as the rest, centred, with the leftover split evenly either side.
        //
        // The weights are read and not used: nothing on the phone sets one any more (see
        // ``MosaicChoice/weight``), and they stay in the signature because a stored arrangement
        // still carries them.
        _ = weights

        let columns = columns(for: count, portrait: portrait)
        let rowCount = Int((Double(count) / Double(columns)).rounded(.up))
        let cell = 1.0 / Double(columns)
        let height = 1.0 / Double(rowCount)

        var rects: [NormalizedRect] = []
        for index in 0..<count {
            let row = index / columns
            let column = index % columns
            // A short row is centred: the same tile as every other, leftover split evenly either
            // side rather than collected at one end.
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
    /// The shape of the arrangement and not of the phone: a canvas is divided into a grid, so its
    /// aspect is the shape of every tile in it, and a portrait phone's would leave a window in a
    /// band across the middle with the rest captured, composited and encoded for nothing. The tiles
    /// get the shape they want, from what the arrangement's windows actually are (see
    /// ``MosaicGrid/windowAspect``); the orientation still decides the grid, see
    /// ``columns(for:portrait:)``.
    ///
    /// The size is the screen's: the largest picture of that shape at the screen's own pixels, with
    /// whichever axis the fit would bind on given the screen's full measurement, so a tile is never
    /// softer than the pixels it lands on. The area cap scales both sides together afterwards, so a
    /// shape a Mac will not build comes back smaller rather than reshaped. Both numbers are rounded
    /// to even here because the encoder rounds down to even, and a client that asked for an odd
    /// canvas would have its rectangles measured against a picture a pixel narrower than the one it
    /// described.
    ///
    /// Turning the phone therefore re-asks for the arrangement, and the Mac tears down and rebuilds
    /// every tile's stream: one short stop in the picture, at the moment the user turned it.
    /// - Parameters:
    ///   - columns: how many tiles are across, from ``columns(for:portrait:)``.
    ///   - tiles: how many there are in total, which is not `columns × rows`: a mosaic of eight is
    ///     three across and three down, and a tile is `1/columns` of the width, so the canvas has to
    ///     be the shape that makes that a window.
    public static func canvas(
        columns: Int,
        tiles: Int,
        tileAspect: Double,
        viewport: CGSize
    ) -> CGSize {
        let columns = max(columns, 1)
        let tiles = max(tiles, 1)
        // From the grid's rows, not from the number of tiles: a cell's shape is the canvas's aspect
        // divided by the shape of the grid, which is `columns` wide and `ceil(tiles/columns)` tall
        // whether or not its last row is full. See ``rects(count:portrait:)``.
        let rows = (Double(tiles) / Double(columns)).rounded(.up)
        let aspect = min(max(Double(columns) / rows * tileAspect, 0.05), 20)

        var width = min(viewport.width, viewport.height * CGFloat(aspect))
        var height = width / CGFloat(aspect)

        let budget = CGFloat(MosaicLayout.maximumCanvasPixels)
        let area = width * height
        if area > budget {
            let scale = (budget / area).squareRoot()
            width *= scale
            height *= scale
        }

        // `floor then halve then floor`, not `divide by two and multiply back`: in floating point
        // those are not the same, and the shorter one leaves an odd number odd.
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

    /// The same, from an arrangement's choices rather than from bare sources.
    ///
    /// The order is the whole of it: the orientation says how many columns, the grid says how many
    /// rows that makes, the number of tiles and their shape say what the canvas is, and the canvas
    /// is what the rectangles are fractions of. `tileAspect` is how wide the things in the
    /// arrangement are, which is the caller's business; see ``MosaicGrid/windowAspect``.
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
    /// ``NormalizedRect/contains(_:)`` is half-open on each far edge, so the line between two tiles
    /// belongs to exactly one of them, and a point outside every rect is the gap rather than the
    /// nearest tile.
    public static func tileIndex(at point: NormalizedPoint, in layout: MosaicLayout) -> Int? {
        layout.tiles.firstIndex { $0.rect.contains(point) }
    }
}
