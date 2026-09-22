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

    @Test("the last row is left aligned rather than stretched")
    func remainderIsNotStretched() {
        // Five tiles are three across and two under them, and those two are the same shape as
        // the three above: stretching them to fill the row would make them a different size
        // from their neighbours, which reads as a bug rather than as a decision. The row is
        // left aligned, so the two under it are the first two columns, and the gap is at the
        // end where the sixth tile would have been.
        let rects = MosaicGrid.rects(count: 5)
        #expect(close(rects[3].x, 0))
        #expect(close(rects[4].x, 1.0 / 3))
        for index in 3...4 {
            #expect(close(rects[index].width, 1.0 / 3))
            #expect(close(rects[index].y, 0.5))
        }
        // And nothing sits in the third column of that row, so a tap there is a gap rather than
        // the nearest window.
        let layout = MosaicGrid.layout(
            sources: (1...5).map { CaptureSource.window(UInt32($0)) },
            viewport: phone
        )
        #expect(layout != nil)
        if let layout {
            #expect(MosaicGrid.tileIndex(at: NormalizedPoint(x: 0.9, y: 0.75), in: layout) == nil)
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
