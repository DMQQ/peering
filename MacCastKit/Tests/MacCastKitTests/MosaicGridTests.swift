import CoreGraphics
import RemoteCore
import Testing

@testable import MacCastKit

@Suite("Arranging a mosaic")
struct MosaicGridTests {
    /// A phone in landscape, in its own pixels.
    private let phone = CGSize(width: 2556, height: 1179)
    /// The same phone held up.
    private let heldUp = CGSize(width: 1179, height: 2556)

    /// Six windows of the shape a window is, laid out for a phone held up.
    private var portrait: MosaicLayout {
        MosaicGrid.layout(choices: choices(6), viewport: heldUp, tileAspect: 1.6)!
    }

    /// The same, held sideways.
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
        // Sideways it has the width for another column, so it rounds up.
        #expect(MosaicGrid.columns(for: 1, portrait: false) == 1)
        #expect(MosaicGrid.columns(for: 2, portrait: false) == 2)
        #expect(MosaicGrid.columns(for: 3, portrait: false) == 2)
        #expect(MosaicGrid.columns(for: 4, portrait: false) == 2)
        #expect(MosaicGrid.columns(for: 5, portrait: false) == 3)
        #expect(MosaicGrid.columns(for: 6, portrait: false) == 3)

        // **Held up it has the height for another row, so it rounds down.** Two columns and three
        // rows of windows make a canvas 1.07:1 — nearly square, and every tile in it the shape of
        // the window it holds. Three columns would make a canvas 1.6:1 whose tiles are three
        // times as wide as they are tall, which is not a shape any Mac window has.
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
        // **The property the whole rule exists for.** Whatever the arrangement, whatever the
        // phone's orientation, a tile's width divided by its height is the aspect that was asked
        // for — which is what stops a landscape window being letterboxed inside its own tile with
        // most of the tile spent on black. Checked over the counts and shapes that actually occur.
        for viewport in [phone, heldUp] {
            for scenario in [(count: 2, aspect: 1.6), (count: 6, aspect: 1.6), (count: 9, aspect: 1.6),
                             (count: 4, aspect: 1.33), (count: 6, aspect: 2.0), (count: 8, aspect: 1.5)] {
                guard let layout = MosaicGrid.layout(
                    choices: choices(scenario.count), viewport: viewport, tileAspect: scenario.aspect
                ) else {
                    Issue.record("no layout for \(scenario.count) tiles at \(scenario.aspect)")
                    return
                }
                // Every tile, a short row's included: they are all the size the grid gives them, so
                // the canvas's shape is the whole of what decides a tile's shape. The case this is
                // here to catch is a short row's tiles being widened to fill their own row, which
                // was the rule before this one. See ``MosaicGrid/rects(weights:portrait:)``.
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
        // Six windows held sideways: three columns by two rows is 2.4:1, which on a 2556x1179
        // screen is the screen's own width and a little over half its height. The canvas is the
        // largest 2.4:1 picture the screen could show, which is that same shape at the screen's
        // pixels — no more than the screen, because nothing draws it larger than that.
        let wide = MosaicGrid.canvas(columns: 3, tiles: 6, tileAspect: 1.6, viewport: phone)
        #expect(abs(Double(wide.width / wide.height) - 2.4) < 0.02)
        #expect(wide.width == 2556)
        #expect(wide.height == 1064)

        // The same six held up: two columns by three rows is 1.07:1, a canvas nearly square, and
        // the width is what binds on a phone this tall.
        let upright = MosaicGrid.canvas(columns: 2, tiles: 6, tileAspect: 1.6, viewport: heldUp)
        #expect(abs(Double(upright.width / upright.height) - 2.0 / 3 * 1.6) < 0.02)
        #expect(upright.width == 1178)
        #expect(upright.height == 1104)

        // **Never more pixels than a Mac will build**, whichever way round it is, and the shape
        // survives the trimming because both sides are scaled together.
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

            // The one thing a grid must never do is let two tiles be drawn in the same place:
            // a tap would then have two answers and the compositor two claims on one rectangle.
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

        // And what that shape is *for*: a tile the shape of the window in it, on a canvas built
        // to make that so. See ``canvasesAreShapedByTheArrangement``.
        let uprightCanvas = MosaicGrid.canvas(columns: 2, tiles: 6, tileAspect: 1.6, viewport: heldUp)
        let tile = Double(upright[0].width * uprightCanvas.width) / Double(upright[0].height * uprightCanvas.height)
        #expect(abs(tile - 1.6) < 0.01, "a portrait tile came out \(tile):1")
    }

    @Test("a row that is not full ends early, aligned with the row above")
    func remainderIsNotStretched() {
        // Five tiles are three across and two under them, and every tile is the size the grid gives
        // it: the last row is two tiles the width of the three above rather than two wider ones.
        //
        // **And the short row starts where the full one does.** The leftover is one band at the
        // canvas's trailing edge rather than a gap split either side of the tiles, because a centred
        // row is read as a layout that went wrong. See ``MosaicGrid/rects(weights:portrait:)``.
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
        // **The contract now, and it replaced a different one.** A tile's area used to be its
        // share of the weights, which meant a row that was not full shared its width between its
        // tiles: five tiles were three across the top and two wider ones under them. Every pixel
        // of the canvas belonged to a tile, which was the reason for it, and the last row's tiles
        // were larger than every other — an arrangement whose tiles differ in size reads as a
        // mistake rather than as a layout.
        //
        // So what is asserted is uniformity itself, which is the one thing a grid can promise.
        // The price is a margin beside a row that is not full, and that is deliberate.
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
        // And nothing outside the picture is a tile at all: a tap there must not select the
        // nearest window.
        #expect(MosaicGrid.tileIndex(at: NormalizedPoint(x: 1.2, y: 0.5), in: layout) == nil)
    }

    @Test("a tile's rectangle on screen is the cursor mapping, applied to a rect")
    func rectMapping() {
        let bounds = CGSize(width: 800, height: 400)
        let pixels = CGSize(width: 1920, height: 1080)
        let rect = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 0.5)

        // **One mapping, two shapes.** The borders are drawn around the same picture the cursor
        // is drawn on, so a rect that did not go through the cursor's own function would be the
        // one thing on screen that is a zoom factor out.
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

        // And with nothing to map into it says so rather than returning a rect at the origin,
        // which would be a border drawn around the corner of the screen.
        #expect(CanvasGeometry.rect(
            normalized: rect, bounds: .zero, pixelSize: pixels, zoom: 1, pan: .zero
        ) == nil)
    }

    @Test("the transform that fills the screen with a tile lands the tile on the screen")
    func fillingTransform() {
        // A picture that is the whole screen at rest, so the numbers are readable: a canvas of
        // 800x400 shown in 800x400 with no zoom and no pan.
        let bounds = CGSize(width: 800, height: 400)
        let pixels = CGSize(width: 800, height: 400)

        // **Checked by mapping the tile back through the transform that was chosen for it**, which
        // is the only claim that matters: the tile has to end up centred on the screen and
        // covering all of it. A sign out sends the picture the wrong way, and it would do it
        // during the one movement in the app that exists to explain what a tap did.
        //
        // Covering rather than matching, for the two tiles that are not the screen's shape: the
        // scale is the larger of the two the axes want, so the tile comes out wider or taller than
        // the screen and the overflow is off the edges. That crop is what a zoom is, and asserting
        // the corners would have been asserting that a 1:1 tile shown on a 2:1 screen is not
        // cropped, which is the one thing it cannot be.
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

            // The one tile that is the screen's own shape fills it exactly, which is the case a
            // user gets most of the time: a 2x2 grid on a landscape phone is four 16:9 tiles on a
            // 16:9 canvas, and the window in it should land edge to edge.
            if tile.width == 0.5, tile.height == 0.5 {
                #expect(abs(mapped.minX) < 0.01 && abs(mapped.minY) < 0.01)
                #expect(abs(mapped.maxX - bounds.width) < 0.01 && abs(mapped.maxY - bounds.height) < 0.01)
            }
        }

        // **The case this exists for: a window inside a tile, moved to where that window will be.**
        // A window keeps its own shape inside whatever rectangle the grid gave it — it is
        // letterboxed, so it is a band across the middle of its tile — and what the animation has
        // to land on is the framing that same window has when it *is* the picture. Two rectangles
        // of the same shape, so the movement between them is one scale and one offset, and when
        // the real stream arrives nothing moves at all.
        // The picture at rest is the whole screen (canvas 800x400 shown in 800x400), so a screen
        // point is a picture point and the normalized position of one is the arithmetic below.
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
        // A window's own picture letterboxed into a 300x400 tile: 16:9, centred, with the tile's
        // black above and below it.
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

        // **It lands on the framing it will have as the picture, to the pixel.** That is the whole
        // claim: the animation ends where the window is going to be, so the moment the Mac's own
        // stream arrives the picture sharpens in place instead of jumping.
        #expect(abs(topLeft.x - destination.minX) < 0.01, "the window landed at \(topLeft)")
        #expect(abs(topLeft.y - destination.minY) < 0.01, "the window landed at \(topLeft)")
        #expect(abs(bottomRight.x - destination.maxX) < 0.01, "the window landed at \(bottomRight)")
        #expect(abs(bottomRight.y - destination.maxY) < 0.01, "the window landed at \(bottomRight)")

        // And a transform that cannot be worked out says so rather than returning zeroes, which
        // would be a picture drawn at no size in the corner of the screen.
        #expect(CanvasGeometry.transform(
            of: .zero, mappingTo: CGRect(origin: .zero, size: bounds), bounds: bounds, zoom: 1, pan: .zero
        ) == nil)
        #expect(CanvasGeometry.transform(
            of: CGRect(x: 0, y: 0, width: 10, height: 10),
            mappingTo: CGRect(origin: .zero, size: bounds), bounds: bounds, zoom: 0, pan: .zero
        ) == nil)
        // A source with no target: nothing to move onto, so nothing to say.
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
