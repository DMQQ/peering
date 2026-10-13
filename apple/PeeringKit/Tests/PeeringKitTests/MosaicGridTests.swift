import CoreGraphics
import RemoteCore
import Testing

@testable import MacCastKit

@Suite("Arranging a mosaic")
struct MosaicGridTests {
    private let phone = CGSize(width: 2556, height: 1179)
    private let heldUp = CGSize(width: 1179, height: 2556)

    private var portrait: MosaicLayout {
        MosaicGrid.layout(choices: choices(6), viewport: heldUp, tileAspect: 1.6)!
    }

    private var landscape: MosaicLayout {
        MosaicGrid.layout(choices: choices(6), viewport: phone, tileAspect: 1.6)!
    }

    private func choices(_ count: Int) -> [MosaicChoice] {
        (0..<count).map { MosaicChoice(source: .window(UInt32($0 + 1))) }
    }

    private func close(_ value: Double, _ expected: Double) -> Bool {
        abs(value - expected) < 0.0001
    }

    @Test("the grid is the square root, rounded to the side the phone has room for")
    func gridShape() {
        #expect(MosaicGrid.columns(for: 1, portrait: false) == 1)
        #expect(MosaicGrid.columns(for: 2, portrait: false) == 2)
        #expect(MosaicGrid.columns(for: 3, portrait: false) == 2)
        #expect(MosaicGrid.columns(for: 4, portrait: false) == 2)
        #expect(MosaicGrid.columns(for: 5, portrait: false) == 3)
        #expect(MosaicGrid.columns(for: 6, portrait: false) == 3)

        // Held up it has the height for another row, so it rounds down: three columns would make tiles three times as wide as tall, a shape no Mac window has.
        #expect(MosaicGrid.columns(for: 1, portrait: true) == 1)
        #expect(MosaicGrid.columns(for: 2, portrait: true) == 1)
        #expect(MosaicGrid.columns(for: 3, portrait: true) == 1)
        #expect(MosaicGrid.columns(for: 4, portrait: true) == 2)
        #expect(MosaicGrid.columns(for: 5, portrait: true) == 2)
        #expect(MosaicGrid.columns(for: 6, portrait: true) == 2)
        #expect(MosaicGrid.columns(for: 9, portrait: true) == 3)
    }

    @Test("every tile in a canvas is the shape the arrangement was built for")
    func canvasesAreShapedByTheArrangement() {
        // A tile's width over its height is the aspect that was asked for, so a landscape window is never letterboxed inside its tile.
        for viewport in [phone, heldUp] {
            for scenario in [(count: 2, aspect: 1.6), (count: 6, aspect: 1.6), (count: 9, aspect: 1.6),
                             (count: 4, aspect: 1.33), (count: 6, aspect: 2.0), (count: 8, aspect: 1.5)] {
                guard let layout = MosaicGrid.layout(
                    choices: choices(scenario.count), viewport: viewport, tileAspect: scenario.aspect
                ) else {
                    Issue.record("no layout for \(scenario.count) tiles at \(scenario.aspect)")
                    return
                }
                // Every tile, a short row's included, is the size the grid gives it: a short row's tiles must not be widened to fill their row. See ``MosaicGrid/rects(weights:portrait:)``.
                for (index, tile) in layout.tiles.enumerated() {
                    let aspect = (tile.rect.width * layout.canvas.width)
                        / (tile.rect.height * layout.canvas.height)
                    #expect(
                        abs(aspect - scenario.aspect) < 0.02,
                        "tile \(index) of \(scenario.count) at \(scenario.aspect) on \(viewport) came out \(aspect)"
                    )
                }
            }
        }
    }

    @Test("a canvas is the largest picture of its shape the screen could show")
    func canvasSize() {
        // The canvas is the largest 2.4:1 picture the screen could show, never larger than the screen.
        let wide = MosaicGrid.canvas(columns: 3, tiles: 6, tileAspect: 1.6, viewport: phone)
        #expect(abs(Double(wide.width / wide.height) - 2.4) < 0.02)
        #expect(wide.width == 2556)
        #expect(wide.height == 1064)

        let upright = MosaicGrid.canvas(columns: 2, tiles: 6, tileAspect: 1.6, viewport: heldUp)
        #expect(abs(Double(upright.width / upright.height) - 2.0 / 3 * 1.6) < 0.02)
        #expect(upright.width == 1178)
        #expect(upright.height == 1104)

        // Never more pixels than a Mac will build, in either orientation; trimming scales both sides together.
        for aspect in [0.4, 1.0, 1.6, 3.0] {
            let huge = MosaicGrid.canvas(columns: 4, tiles: 4, tileAspect: aspect, viewport: CGSize(width: 6016, height: 3384))
            #expect(Int(huge.width * huge.height) <= MosaicLayout.maximumCanvasPixels)
            #expect(abs(Double(huge.width / huge.height) - 4 * aspect) < 0.05, "a \(aspect) arrangement was reshaped")
            #expect(huge.width.truncatingRemainder(dividingBy: 2) == 0)
            #expect(huge.height.truncatingRemainder(dividingBy: 2) == 0)
        }
    }

    @Test("every tile is inside the canvas, and no two of them overlap")
    func rectanglesCoverTheCanvas() {
        for portrait in [false, true] {
            rectanglesCover(portrait)
        }
    }

    private func rectanglesCover(_ portrait: Bool) {
        for count in 1...MosaicLayout.maximumTileCount {
            let rects = MosaicGrid.rects(count: count, portrait: portrait)
            #expect(rects.count == count)

            for rect in rects {
                #expect(rect.x >= 0 && rect.y >= 0)
                #expect(rect.x + rect.width <= 1.0001)
                #expect(rect.y + rect.height <= 1.0001)
                #expect(rect.width > 0 && rect.height > 0)
            }

            // Two tiles must never be drawn in the same place: a tap would have two answers.
            for outer in rects.indices {
                for inner in rects.indices where inner > outer {
                    let a = rects[outer]
                    let b = rects[inner]
                    let overlapX = a.x < b.x + b.width - 0.0001 && b.x < a.x + a.width - 0.0001
                    let overlapY = a.y < b.y + b.height - 0.0001 && b.y < a.y + a.height - 0.0001
                    #expect(!(overlapX && overlapY), "tiles \(outer) and \(inner) overlap at \(count) tiles")
                }
            }
        }
    }

    @Test("six tiles are three across on a landscape phone and two across on an upright one")
    func sixTiles() {
        let wide = MosaicGrid.rects(count: 6, portrait: false)
        #expect(close(wide[0].width, 1.0 / 3))
        #expect(close(wide[0].height, 0.5))
        #expect(close(wide[5].x, 2.0 / 3))
        #expect(close(wide[5].y, 0.5))

        let upright = MosaicGrid.rects(count: 6, portrait: true)
        #expect(close(upright[0].width, 0.5))
        #expect(close(upright[0].height, 1.0 / 3))
        #expect(close(upright[5].x, 0.5))
        #expect(close(upright[5].y, 2.0 / 3))

        let uprightCanvas = MosaicGrid.canvas(columns: 2, tiles: 6, tileAspect: 1.6, viewport: heldUp)
        let tile = Double(upright[0].width * uprightCanvas.width) / Double(upright[0].height * uprightCanvas.height)
        #expect(abs(tile - 1.6) < 0.01, "a portrait tile came out \(tile):1")
    }

    @Test("a row that is not full ends early, aligned with the row above")
    func remainderIsNotStretched() {
        // Five tiles are three across and two under, every tile the size the grid gives it, and the short row starts where the full one does: a centred row reads as a layout gone wrong. See ``MosaicGrid/rects(weights:portrait:)``.
        let rects = MosaicGrid.rects(count: 5, portrait: false)
        for index in 0...2 {
            #expect(close(rects[index].width, 1.0 / 3))
            #expect(close(rects[index].height, 0.5))
            #expect(close(rects[index].y, 0))
        }
        #expect(close(rects[3].x, 0))
        #expect(close(rects[4].x, 1.0 / 3))
        for index in 3...4 {
            #expect(close(rects[index].width, 1.0 / 3))
            #expect(close(rects[index].height, 0.5))
            #expect(close(rects[index].y, 0.5))
        }
    }

    @Test("every tile is the same size, whatever the count and the shape of the screen")
    func everyTileIsTheSameSize() {
        // Uniformity is asserted: tiles used to share their weights' area, so a short last row's tiles were wider than the rest, which reads as a mistake. The margin beside a short row is deliberate.
        for portrait in [false, true] {
            for count in 2...8 {
                let rects = MosaicGrid.rects(count: count, portrait: portrait)
                let first = rects[0].width * rects[0].height
                for (index, rect) in rects.enumerated() {
                    #expect(
                        abs(rect.width * rect.height - first) < 0.0001,
                        "tile \(index) of \(count) portrait \(portrait) is \(rect.width * rect.height), not \(first)"
                    )
                }
            }
        }
    }

    @Test("hit testing names one tile, the seam belongs to one of them, and a gap names none")
    func hitTesting() {
        let layout = MosaicGrid.layout(sources: [.window(1), .window(2)], viewport: phone)
        #expect(layout != nil)
        guard let layout else { return }

        #expect(MosaicGrid.tileIndex(at: NormalizedPoint(x: 0.1, y: 0.5), in: layout) == 0)
        #expect(MosaicGrid.tileIndex(at: NormalizedPoint(x: 0.6, y: 0.5), in: layout) == 1)
        // The line where two tiles meet is half-open, so it belongs to exactly one of them.
        #expect(MosaicGrid.tileIndex(at: NormalizedPoint(x: 0.5, y: 0.5), in: layout) == 1)
        #expect(MosaicGrid.tileIndex(at: NormalizedPoint(x: 1.2, y: 0.5), in: layout) == nil)
    }

    @Test("a tile's rectangle on screen is the cursor mapping, applied to a rect")
    func rectMapping() {
        let bounds = CGSize(width: 800, height: 400)
        let pixels = CGSize(width: 1920, height: 1080)
        let rect = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 0.5)

        // The borders are drawn around the same picture the cursor is drawn on, so they must go through the cursor's own mapping.
        for (zoom, pan) in [(CGFloat(1), CGSize.zero), (2.5, CGSize(width: -30, height: 12))] {
            let mapped = CanvasGeometry.rect(
                normalized: rect, bounds: bounds, pixelSize: pixels, zoom: zoom, pan: pan
            )
            let topLeft = CanvasGeometry.point(
                normalized: NormalizedPoint(x: 0.5, y: 0), bounds: bounds, pixelSize: pixels, zoom: zoom, pan: pan
            )
            let bottomRight = CanvasGeometry.point(
                normalized: NormalizedPoint(x: 1, y: 0.5), bounds: bounds, pixelSize: pixels, zoom: zoom, pan: pan
            )
            #expect(mapped != nil)
            guard let mapped, let topLeft, let bottomRight else { return }
            #expect(abs(mapped.minX - topLeft.x) < 0.001)
            #expect(abs(mapped.minY - topLeft.y) < 0.001)
            #expect(abs(mapped.maxX - bottomRight.x) < 0.001)
            #expect(abs(mapped.maxY - bottomRight.y) < 0.001)
            #expect(mapped.width > 0 && mapped.height > 0)
        }

        #expect(CanvasGeometry.rect(
            normalized: rect, bounds: .zero, pixelSize: pixels, zoom: 1, pan: .zero
        ) == nil)
    }

    @Test("the transform that fills the screen with a tile lands the tile on the screen")
    func fillingTransform() {
        let bounds = CGSize(width: 800, height: 400)
        let pixels = CGSize(width: 800, height: 400)

        // Checked by mapping the tile back through the chosen transform: it must end up centred on the screen and covering it. Covering rather than matching for tiles not the screen's shape: the overflow is the crop a zoom is.
        for tile in [
            NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1),
            NormalizedRect(x: 0, y: 0.5, width: 1, height: 0.5),
            NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
        ] {
            guard let rect = CanvasGeometry.rect(
                normalized: tile, bounds: bounds, pixelSize: pixels, zoom: 1, pan: .zero
            ), let target = CanvasGeometry.transform(
                of: rect, mappingTo: CGRect(origin: .zero, size: bounds), bounds: bounds, zoom: 1, pan: .zero
            ), let mapped = CanvasGeometry.rect(
                normalized: tile, bounds: bounds, pixelSize: pixels,
                zoom: target.zoom, pan: target.pan
            ) else {
                Issue.record("the tile at \(tile) could not be mapped or filled")
                return
            }

            let screen = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
            #expect(abs(mapped.midX - screen.x) < 0.01, "the tile at \(tile) landed at \(mapped)")
            #expect(abs(mapped.midY - screen.y) < 0.01, "the tile at \(tile) landed at \(mapped)")
            #expect(mapped.width >= bounds.width - 0.01, "the tile at \(tile) left the screen uncovered")
            #expect(mapped.height >= bounds.height - 0.01, "the tile at \(tile) left the screen uncovered")

            if tile.width == 0.5, tile.height == 0.5 {
                #expect(abs(mapped.minX) < 0.01 && abs(mapped.minY) < 0.01)
                #expect(abs(mapped.maxX - bounds.width) < 0.01 && abs(mapped.maxY - bounds.height) < 0.01)
            }
        }

        // A window keeps its own shape letterboxed inside its tile, and the animation must land on the framing it has as the picture, so nothing moves when the real stream arrives.
        // The picture at rest is the whole screen, so a screen point is a picture point.
        let video = CanvasGeometry.videoRect(bounds: bounds, pixelSize: pixels)
        func whereItLanded(_ corner: CGPoint, _ transform: (zoom: CGFloat, pan: CGSize)) -> CGPoint? {
            CanvasGeometry.point(
                normalized: NormalizedPoint(
                    x: Double((corner.x - video.minX) / video.width),
                    y: Double((corner.y - video.minY) / video.height)
                ),
                bounds: bounds, pixelSize: pixels, zoom: transform.zoom, pan: transform.pan
            )
        }

        let wide = CGSize(width: 1920, height: 1080)
        let insideTile = CGRect(x: 0, y: (400 - 300 * 9.0 / 16) / 2, width: 300, height: 300 * 9.0 / 16)
        let destination = CanvasGeometry.videoRect(bounds: bounds, pixelSize: wide)
        guard let moved = CanvasGeometry.transform(
            of: insideTile, mappingTo: destination, bounds: bounds, zoom: 1, pan: .zero
        ), let topLeft = whereItLanded(insideTile.origin, moved),
           let bottomRight = whereItLanded(CGPoint(x: insideTile.maxX, y: insideTile.maxY), moved)
        else {
            Issue.record("the window inside a tile could not be moved")
            return
        }

        // It lands on the framing it will have as the picture, to the pixel, so the picture sharpens in place instead of jumping.
        #expect(abs(topLeft.x - destination.minX) < 0.01, "the window landed at \(topLeft)")
        #expect(abs(topLeft.y - destination.minY) < 0.01, "the window landed at \(topLeft)")
        #expect(abs(bottomRight.x - destination.maxX) < 0.01, "the window landed at \(bottomRight)")
        #expect(abs(bottomRight.y - destination.maxY) < 0.01, "the window landed at \(bottomRight)")

        #expect(CanvasGeometry.transform(
            of: .zero, mappingTo: CGRect(origin: .zero, size: bounds), bounds: bounds, zoom: 1, pan: .zero
        ) == nil)
        #expect(CanvasGeometry.transform(
            of: CGRect(x: 0, y: 0, width: 10, height: 10),
            mappingTo: CGRect(origin: .zero, size: bounds), bounds: bounds, zoom: 0, pan: .zero
        ) == nil)
        #expect(CanvasGeometry.transform(
            of: CGRect(x: 0, y: 0, width: 10, height: 10),
            mappingTo: .zero, bounds: bounds, zoom: 1, pan: .zero
        ) == nil)
    }

    @Test("no sources is no mosaic, and one source is a mosaic of one")
    func counts() {
        #expect(MosaicGrid.layout(sources: [], viewport: phone) == nil)

        let single = MosaicGrid.layout(sources: [.display(1)], viewport: phone)
        #expect(single?.tiles.count == 1)
        #expect(single?.tiles.first?.rect == NormalizedRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test("a mosaic carries the sources it was built from, in order")
    func layoutCarriesSources() {
        let sources: [CaptureSource] = [.display(1), .application(402), .window(17)]
        let layout = MosaicGrid.layout(sources: sources, viewport: phone)
        #expect(layout?.tiles.map(\.source) == sources)
        #expect(layout?.frameRate == MosaicGrid.defaultFrameRate)
        // Three sources sideways are two columns, which is the canvas the layout is
        // a set of fractions of. See ``MosaicGrid/canvas(columns:rows:tileAspect:viewport:)``.
        #expect(layout?.canvas == MosaicGrid.canvas(columns: 2, tiles: 3, tileAspect: 1.6, viewport: phone))
    }
}
