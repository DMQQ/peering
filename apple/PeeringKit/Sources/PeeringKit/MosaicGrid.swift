import CoreGraphics
import Foundation
import RemoteCore

/// Arranging tiles on the phone: how many fit, where they sit, and how big the canvas is.
public struct MosaicChoice: Codable, Equatable, Sendable {
    public var source: CaptureSource
    public var weight: Int

    public init(source: CaptureSource, weight: Int = 1) {
        self.source = source
        self.weight = weight
    }

    /// The weights the size control steps between, so the button and the arithmetic cannot disagree.
    public static let maximumWeight = 3
    public static let minimumWeight = 1
}

public enum MosaicArrangementStore {
    private static let key = "Peering.mosaicArrangements"

    private static func arrangements() -> [String: [MosaicChoice]] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode([String: [MosaicChoice]].self, from: data)
        else { return [:] }
        return stored
    }

    public static func load(hostID: String) -> [MosaicChoice] {
        arrangements()[hostID] ?? []
    }

    public static func save(_ choices: [MosaicChoice], hostID: String) {
        var stored = arrangements()
        if choices.count > 1 {
            stored[hostID] = choices
        } else {
            stored.removeValue(forKey: hostID)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

public enum MosaicArrangement {
    /// The remembered arrangement, thinned to the sources this Mac still has.
    public static func restored(_ choices: [MosaicChoice], into catalog: CaptureCatalog?) -> [MosaicChoice] {
        guard let catalog else { return [] }
        let living = choices.filter { catalog.descriptor(for: $0.source) != nil }
        return living.count > 1 ? living : []
    }
}

public enum MosaicGrid {
    /// The rate a mosaic is asked for unless the user says otherwise.
    public static let defaultFrameRate = 15

    /// The shape a tile is drawn at when nothing in the arrangement says otherwise.
    public static let windowAspect: Double = 1.6

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

    public static func rects(weights: [Int], portrait: Bool) -> [NormalizedRect] {
        let weights = weights.map { max($0, 1) }
        let count = weights.count
        guard count > 0 else { return [] }

        // Every tile is the same size, which is what a grid is: a short row holds tiles the same
        // size as the rest and simply ends early, its leftover collected as one band at the canvas's
        // trailing edge rather than split around the tiles.
        _ = weights

        let columns = columns(for: count, portrait: portrait)
        let rowCount = Int((Double(count) / Double(columns)).rounded(.up))
        let cell = 1.0 / Double(columns)
        let height = 1.0 / Double(rowCount)

        var rects: [NormalizedRect] = []
        for index in 0..<count {
            let row = index / columns
            let column = index % columns
            rects.append(NormalizedRect(
                x: cell * Double(column),
                y: height * Double(row),
                width: cell,
                height: height
            ))
        }
        return rects
    }

    /// The canvas to ask a Mac for: the shape of the arrangement, at the screen's own pixels.
    public static func canvas(
        columns: Int,
        tiles: Int,
        tileAspect: Double,
        viewport: CGSize
    ) -> CGSize {
        let columns = max(columns, 1)
        let tiles = max(tiles, 1)
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

        func even(_ value: CGFloat) -> CGFloat {
            max(2, (value / 2).rounded(.down) * 2)
        }
        return CGSize(width: even(width), height: even(height))
    }

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

    public static func tileIndex(at point: NormalizedPoint, in layout: MosaicLayout) -> Int? {
        layout.tiles.firstIndex { $0.rect.contains(point) }
    }
}
