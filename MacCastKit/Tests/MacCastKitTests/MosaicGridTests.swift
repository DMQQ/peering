import CoreGraphics
import RemoteCore
import Testing

@testable import MacCastKit

@Suite("Arranging a mosaic")
struct MosaicGridTests {
    /// A phone in landscape, in its own pixels.
    private let phone = CGSize(width: 2556, height: 1179)

    private func close(_ value: Double, _ expected: Double) -> Bool {
        abs(value - expected) < 0.0001
    }

    @Test("the grid is the fewest square columns that hold the tiles")
    func gridShape() {
        #expect(MosaicGrid.columns(for: 1) == 1)
        #expect(MosaicGrid.columns(for: 2) == 2)
        #expect(MosaicGrid.columns(for: 3) == 2)
        #expect(MosaicGrid.columns(for: 4) == 2)
        #expect(MosaicGrid.columns(for: 5) == 3)
        #expect(MosaicGrid.columns(for: 6) == 3)
    }

    @Test("every tile is inside the canvas, and no two of them overlap")
    func rectanglesCoverTheCanvas() {
        for count in 1...MosaicLayout.maximumTileCount {
            let rects = MosaicGrid.rects(count: count)
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

    @Test("six tiles on a landscape phone are three across and two down")
    func sixTiles() {
        let rects = MosaicGrid.rects(count: 6)
        #expect(close(rects[0].width, 1.0 / 3))
        #expect(close(rects[0].height, 0.5))
        #expect(close(rects[5].x, 2.0 / 3))
        #expect(close(rects[5].y, 0.5))
    }

    @Test("a row that is not full is shorter, and fills its own width")
    func remainderIsNotStretched() {
        // Five tiles are three across and two under them. The rows are sized by what they hold,
        // so the last one is two fifths of the height rather than a half — there is no empty slot
        // in the picture, which is what makes every point on the canvas belong to a tile.
        //
        // And those two share their own row rather than keeping a third each: a row that left a
        // third of itself empty would put a tap on the canvas in a place that selects nothing.
        // See ``MosaicGrid/rects(weights:)``.
        let rects = MosaicGrid.rects(count: 5)
        for index in 0...2 {
            #expect(close(rects[index].width, 1.0 / 3))
            #expect(close(rects[index].height, 0.6))
        }
        #expect(close(rects[3].x, 0))
        #expect(close(rects[4].x, 0.5))
        for index in 3...4 {
            #expect(close(rects[index].width, 0.5))
            #expect(close(rects[index].y, 0.6))
            #expect(close(rects[index].height, 0.4))
        }
    }

    @Test("a heavier tile takes its share of the whole canvas")
    func weights() {
        // **The contract, and the only one worth stating: area is the share of the weights.**
        // That is what "this one matters more" has to mean for the control to be one thing rather
        // than a different thing in every arrangement, and it is what the slice-and-dice
        // arithmetic is for: a row's height is its tiles' share of the whole, and inside a row
        // each tile takes its own share of the width.
        for weights in [[2, 1], [3, 1], [1, 2, 1], [3, 2, 3, 1, 1, 2], [2, 1, 1, 1, 1, 1, 1]] {
            let rects = MosaicGrid.rects(weights: weights)
            let total = Double(weights.reduce(0, +))
            for (index, rect) in rects.enumerated() {
                let expected = Double(weights[index]) / total
                #expect(
                    abs(rect.width * rect.height - expected) < 0.0001,
                    "tile \(index) of \(weights) took \(rect.width * rect.height), not \(expected)"
                )
            }
        }

        // Weight cannot be zero or negative: the arithmetic divides by it, and a tile that is
        // set to nothing is a window the user can no longer see at all.
        let clamped = MosaicGrid.rects(weights: [0, -3])
        #expect(close(clamped[0].width, 0.5))
        #expect(close(clamped[1].width, 0.5))
    }

    @Test("any weights at all still tile the canvas exactly")
    func weightsAlwaysFillTheCanvas() {
        for weights in [[1, 1], [3, 1], [1, 2, 1], [3, 2, 3, 1, 1, 2], [2, 2, 2, 2, 2, 2, 2]] {
            let rects = MosaicGrid.rects(weights: weights)
            let area = rects.reduce(0.0) { $0 + $1.width * $1.height }
            #expect(abs(area - 1) < 0.0001, "weights \(weights) left \(1 - area) of the canvas unclaimed")
        }
    }

    @Test("a canvas is the screen's own pixels, rounded to even, and capped")
    func canvasSize() {
        let canvas = MosaicGrid.canvas(for: phone)
        #expect(canvas.width == 2556)
        // Odd heights are rounded down, because the encoder rounds down to even and a client that
        // asked for an odd canvas would have its rectangles measured against a picture one pixel
        // narrower than the one it described.
        #expect(canvas.height == 1178)
        #expect(canvas.height.truncatingRemainder(dividingBy: 2) == 0)

        // And a screen larger than a Mac will build is asked for at the cap, not refused.
        let huge = MosaicGrid.canvas(for: CGSize(width: 6016, height: 3384))
        #expect(huge.width == 2560)
        #expect(huge.height == 1440)
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
        #expect(layout?.canvas == MosaicGrid.canvas(for: phone))
    }
}
