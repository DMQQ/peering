import CoreGraphics
import RemoteCore
import Testing

@testable import MacCastKit

@Suite("The movement between an arrangement and one of its windows")
struct MosaicZoomTests {
    /// The screen the phone draws on, in points, in both orientations.
    private let sideways = CGSize(width: 852, height: 393)
    private let upright = CGSize(width: 393, height: 852)

    /// The pixels a canvas of an arrangement is built at, for the shape ``MosaicGrid`` would ask
    /// a Mac for. Only its *shape* matters here, which is what the tiles are fractions of.
    private func canvas(for count: Int, viewport: CGSize) -> CGSize {
        MosaicGrid.canvas(
            columns: MosaicGrid.columns(for: count, portrait: viewport.height > viewport.width),
            tiles: count,
            tileAspect: 1.54,
            viewport: CGSize(width: viewport.width * 2, height: viewport.height * 2)
        )
    }

    private func layout(count: Int, viewport: CGSize) -> MosaicLayout {
        let pixels = canvas(for: count, viewport: viewport)
        let columns = MosaicGrid.columns(for: count, portrait: viewport.height > viewport.width)
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        let tiles = (0..<count).map { index in
            MosaicTile(
                source: .window(UInt32(index + 1)),
                rect: NormalizedRect(
                    x: Double(index % columns) / Double(columns),
                    y: Double(index / columns) / Double(rows),
                    width: 1 / Double(columns),
                    height: 1 / Double(rows)
                )
            )
        }
        return MosaicLayout(canvas: pixels, tiles: tiles, frameRate: 15)
    }

    /// A window of the shape most windows are, in pixels.
    private let windowPixels = CGSize(width: 1512, height: 982)

    /// Where a picture's whole rectangle is drawn: the one expression every rectangle in this app
    /// that lands on a picture goes through.
    private func drawn(
        pixelSize: CGSize,
        bounds: CGSize,
        zoom: CGFloat,
        pan: CGSize = .zero
    ) -> CGRect? {
        CanvasGeometry.rect(
            normalized: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
            bounds: bounds,
            pixelSize: pixelSize,
            zoom: zoom,
            pan: pan
        )
    }

    private func close(_ a: CGRect, _ b: CGRect, within tolerance: CGFloat = 0.5) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    @Test("the window is drawn at the end of the movement exactly where the reset leaves it")
    func theOpeningLandsWhereTheResetDoes() {
        // **The one property the whole movement rests on**, and the one that was false.
        // Opening a tile scales the canvas until the tapped window fills the screen; the Mac
        // then sends that window's own stream, and the switch resets the zoom to 1. If the
        // movement stopped anywhere else, the picture moves again the moment the stream arrives
        // — which is the zoom in and back out this is meant to explain.
        for viewport in [sideways, upright] {
            for count in [2, 4, 6, 9] {
                for scalesToFill in [false, true] {
                    let layout = layout(count: count, viewport: viewport)
                    // The chrome's margin is the landscape half of the picture's scale; the
                    // number itself belongs to the app, so any value proves the same point.
                    let scale = PictureScale(
                        scalesToFill: scalesToFill,
                        inset: viewport.width > viewport.height ? ChromeMetricsProbe.pictureInset : 0
                    )

                    for index in layout.tiles.indices {
                        let current = scale.base(pixelSize: layout.canvas, in: viewport)
                        guard let target = MosaicZoom.opening(
                            layout: layout, index: index,
                            sourceSize: windowPixels,
                            bounds: viewport,
                            effectiveZoom: current, pan: .zero,
                            scale: scale
                        ) else {
                            Issue.record("tile \(index) of \(count) in \(viewport) has a movement")
                            return
                        }

                        // At the end of the movement: the window's own rectangle, drawn through
                        // the canvas, at the stored zoom the movement asked for.
                        guard let end = CanvasGeometry.rect(
                            normalized: layout.tiles[index].rect,
                            bounds: viewport, pixelSize: layout.canvas,
                            zoom: current * target.zoom, pan: target.pan
                        ).flatMap({ tile in MosaicTileFit.windowRect(sourceSize: windowPixels, in: tile) })
                        else {
                            Issue.record("the tile's window has a rectangle")
                            return
                        }

                        // And after the switch: the window's own stream at its own fit, reset.
                        let rest = scale.base(pixelSize: windowPixels, in: viewport)
                        guard let after = drawn(pixelSize: windowPixels, bounds: viewport, zoom: rest) else {
                            Issue.record("the window's stream has a rectangle")
                            return
                        }

                        #expect(close(end, after), """
                            \(count) tiles, fill \(scalesToFill), tile \(index) of \(viewport): \
                            the movement ends at \(end) and the picture lands at \(after)
                            """)
                    }
                }
            }
        }
    }

    @Test("the movement ends where the stream lands, for the shapes a device actually has")
    func theDeviceShapeLands() {
        // **The test above starts from an arrangement whose rows are full and a window whose shape
        // is the arrangement's**, and that is a degenerate pair: a window of the tile's own aspect
        // fills its tile exactly, so the letterboxing that `MosaicTileFit` does never happens. The
        // numbers here are a real tap on a phone — portrait, a window of a shape nothing like the
        // tile's, and every tile count the grid can produce.
        let viewport = CGSize(width: 430, height: 932)
        for window in [
            CGSize(width: 1920, height: 1050),
            CGSize(width: 902, height: 1126),
            CGSize(width: 1512, height: 982),
            CGSize(width: 600, height: 1400)
        ] {
            for count in [2, 3, 4, 5, 6, 9] {
                for aspect in [0.75, 1.0, 1.19, 1.54, 1.78, 2.0, 2.6, 3.0] {
                    let choices = (0..<count).map { MosaicChoice(source: .window(UInt32($0 + 1))) }
                    guard let layout = MosaicGrid.layout(
                        choices: choices, viewport: viewport, tileAspect: aspect
                    ) else { continue }
                    let scale = PictureScale(scalesToFill: false, inset: 0)

                    for index in layout.tiles.indices {
                        let current = scale.base(pixelSize: layout.canvas, in: viewport)
                        guard let target = MosaicZoom.opening(
                            layout: layout, index: index, sourceSize: window,
                            bounds: viewport, effectiveZoom: current, pan: .zero, scale: scale
                        ) else { continue }

                        guard let end = CanvasGeometry.rect(
                            normalized: layout.tiles[index].rect,
                            bounds: viewport, pixelSize: layout.canvas,
                            zoom: current * target.zoom, pan: target.pan
                        ).flatMap({ MosaicTileFit.windowRect(sourceSize: window, in: $0) })
                        else { continue }

                        let rest = scale.base(pixelSize: window, in: viewport)
                        guard let after = drawn(pixelSize: window, bounds: viewport, zoom: rest)
                        else { continue }

                        #expect(close(end, after), """
                            window \(window), \(count) tiles, aspect \(aspect), tile \(index) of \
                            a \(layout.canvas) canvas: the movement ends at \(end) and the \
                            picture lands at \(after)
                            """)
                    }
                }
            }
        }
    }

    @Test("the way back ends where the arrangement's own rest state is")
    func theReturnLandsWhereTheArrangementDoes() {
        for viewport in [sideways, upright] {
            for count in [2, 4, 6] {
                for scalesToFill in [false, true] {
                    let layout = layout(count: count, viewport: viewport)
                    let scale = PictureScale(
                        scalesToFill: scalesToFill,
                        inset: viewport.width > viewport.height ? ChromeMetricsProbe.pictureInset : 0
                    )

                    for index in layout.tiles.indices {
                        // The state the movement starts in: that window on its own, reset.
                        let rest = scale.base(pixelSize: windowPixels, in: viewport)
                        guard let target = MosaicZoom.returning(
                            layout: layout, sourceID: layout.tiles[index].source.stableID,
                            sourceSize: windowPixels,
                            bounds: viewport,
                            effectiveZoom: rest, pan: .zero,
                            scale: scale
                        ) else {
                            Issue.record("a window of the arrangement has a way back")
                            return
                        }

                        // The window at the end of the movement, drawn through the picture that
                        // is still on screen — the window itself.
                        guard let end = drawn(
                            pixelSize: windowPixels, bounds: viewport,
                            zoom: rest * target.zoom, pan: target.pan
                        ) else {
                            Issue.record("the window has a rectangle")
                            return
                        }

                        // And where it sits in the arrangement that arrives: its tile, drawn at
                        // the canvas's own rest state.
                        let canvasBase = scale.base(pixelSize: layout.canvas, in: viewport)
                        guard let tile = CanvasGeometry.rect(
                            normalized: layout.tiles[index].rect,
                            bounds: viewport, pixelSize: layout.canvas,
                            zoom: canvasBase, pan: .zero
                        ).flatMap({ MosaicTileFit.windowRect(sourceSize: windowPixels, in: $0) })
                        else {
                            Issue.record("the tile has a window rectangle")
                            return
                        }

                        #expect(close(end, tile), """
                            \(count) tiles, fill \(scalesToFill), tile \(index) of \(viewport): \
                            the return ends at \(end) and the tile holds \(tile)
                            """)
                    }
                }
            }
        }
    }

    @Test("both ends of the movement are the same shape, which is what makes it a straight scale")
    func bothEndsOfTheMovementAgree() {
        // **Where the window is and where it is going have to be the same shape**, or the scale
        // between them is not one number and ``CanvasGeometry/transform(of:mappingTo:bounds:zoom:pan:)``
        // has to pick the larger of two ratios — leaving the picture covering the rectangle it
        // was aimed at and overflowing on the other axis. That is exactly what a tile whose
        // surface is not the window's shape produces.
        let viewport = sideways
        let layout = layout(count: 6, viewport: viewport)
        let scale = PictureScale(scalesToFill: false, inset: 0.125)
        let canvasBase = scale.base(pixelSize: layout.canvas, in: viewport)
        let windowAspect = windowPixels.width / windowPixels.height

        for index in layout.tiles.indices {
            guard let tile = CanvasGeometry.rect(
                normalized: layout.tiles[index].rect,
                bounds: viewport, pixelSize: layout.canvas,
                zoom: canvasBase, pan: .zero
            ), let window = MosaicTileFit.windowRect(sourceSize: windowPixels, in: tile)
            else {
                Issue.record("the tile has a window rectangle")
                return
            }
            // Where it is now, and where it will be when it is the whole picture.
            let destination = CanvasGeometry.videoRect(bounds: viewport, pixelSize: windowPixels)

            #expect(abs(window.width / window.height - windowAspect) < 0.001)
            #expect(abs(destination.width / destination.height - windowAspect) < 0.001)
        }
    }

    @Test("a picture put where a movement has it is drawn exactly there")
    func placingKeepsThePictureStill() {
        // **The property that makes a stream arriving mid-movement continuous.** The movement is
        // carrying a window between two rectangles; the Mac builds the new stream in less time
        // than that takes, so the picture changes part-way. What must not happen is the arriving
        // picture being read through the *movement's* state, which belongs to the arrangement and
        // draws this window two or three times too big. So the state is solved for instead: the
        // piece of the arriving picture that is being carried is put on the rectangle the movement
        // already has it in, and the picture does not move.
        let viewport = upright
        let layout = layout(count: 4, viewport: viewport)
        let scale = PictureScale(scalesToFill: false, inset: 0)
        let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

        // The window's own picture, in the middle of a movement: drawn somewhere between its tile
        // and the whole screen, at whatever size the moment has reached.
        let midway = CGRect(x: 60, y: 320, width: 270, height: 175)
        guard let placed = MosaicZoom.placing(
            pixelSize: windowPixels, anchor: full, at: midway,
            bounds: viewport, scale: scale
        ) else {
            Issue.record("the picture can be placed on a rectangle")
            return
        }

        // Drawn at the state the answer gives, the window occupies exactly that rectangle.
        guard let drawn = CanvasGeometry.rect(
            normalized: full, bounds: viewport, pixelSize: windowPixels,
            zoom: scale.base(pixelSize: windowPixels, in: viewport) * placed.zoom,
            pan: placed.pan
        ) else {
            Issue.record("the window has a rectangle")
            return
        }
        #expect(close(drawn, midway, within: 1))

        // And placed on its own rest rectangle, the answer is the rest state — which is why an
        // arrival that the movement did not overtake needs no movement at all.
        let rest = scale.scaled(
            CanvasGeometry.videoRect(bounds: viewport, pixelSize: windowPixels),
            in: viewport,
            by: scale.base(pixelSize: windowPixels, in: viewport)
        )
        guard let atRest = MosaicZoom.placing(
            pixelSize: windowPixels, anchor: full, at: rest,
            bounds: viewport, scale: scale
        ) else {
            Issue.record("the picture can be placed on its rest rectangle")
            return
        }
        #expect(abs(atRest.zoom - 1) < 0.001)
        #expect(abs(atRest.pan.width) < 0.5)
        #expect(abs(atRest.pan.height) < 0.5)

        // A tile's worth of an arrangement is placed the same way: the piece that is carried is
        // the part that has to land, not the whole canvas.
        guard let index = layout.tiles.firstIndex(where: { $0.source == .window(1) }),
              let tile = CanvasGeometry.rect(
                  normalized: layout.tiles[index].rect, bounds: viewport,
                  pixelSize: layout.canvas, zoom: 1, pan: .zero
              ),
              let anchor = MosaicTileFit.windowRect(sourceSize: windowPixels, in: tile)
        else {
            Issue.record("the tile has a window")
            return
        }
        let piece = NormalizedRect(
            x: Double(anchor.minX / layout.canvas.width),
            y: Double(anchor.minY / layout.canvas.height),
            width: Double(anchor.width / layout.canvas.width),
            height: Double(anchor.height / layout.canvas.height)
        )
        guard let canvasPlaced = MosaicZoom.placing(
            pixelSize: layout.canvas, anchor: piece, at: midway,
            bounds: viewport, scale: scale
        ) else {
            Issue.record("the canvas can be placed on a rectangle")
            return
        }
        let canvasBase = scale.base(pixelSize: layout.canvas, in: viewport)
        guard let drawnTile = CanvasGeometry.rect(
            normalized: piece, bounds: viewport, pixelSize: layout.canvas,
            zoom: canvasBase * canvasPlaced.zoom, pan: canvasPlaced.pan
        ) else {
            Issue.record("the piece of the canvas has a rectangle")
            return
        }
        #expect(close(drawnTile, midway, within: 2))
    }

    @Test("a source the catalogue cannot size has no movement in either direction")
    func anUnknownSourceDoesNotMove() {
        // Which is the answer that matters: guessed at, the destination becomes the whole screen
        // and the picture zooms until the *tile* covers it before the reset pulls it back.
        let viewport = upright
        let layout = layout(count: 4, viewport: viewport)
        let scale = PictureScale(scalesToFill: false, inset: 0)
        let base = scale.base(pixelSize: layout.canvas, in: viewport)

        #expect(MosaicZoom.opening(
            layout: layout, index: 0, sourceSize: nil,
            bounds: viewport, effectiveZoom: base, pan: .zero, scale: scale
        ) == nil)
        #expect(MosaicZoom.returning(
            layout: layout, sourceID: layout.tiles[0].source.stableID, sourceSize: nil,
            bounds: viewport, effectiveZoom: 1, pan: .zero, scale: scale
        ) == nil)

        // And a source that is not in the arrangement has no way back either.
        #expect(MosaicZoom.returning(
            layout: layout, sourceID: CaptureSource.window(999).stableID, sourceSize: windowPixels,
            bounds: viewport, effectiveZoom: 1, pan: .zero, scale: scale
        ) == nil)
    }

    @Test("Fill is a different scale for a canvas than for one of its windows")
    func fillDiffersByPicture() {
        // The distinction that makes ``PictureScale`` a value: aiming the movement at the
        // *canvas's* fill, which is what the code did, leaves the window drawn at the wrong size
        // for the whole of the movement and corrects it when the stream arrives.
        let viewport = upright
        let layout = layout(count: 4, viewport: viewport)
        let scale = PictureScale(scalesToFill: true, inset: 0)

        #expect(scale.base(pixelSize: layout.canvas, in: viewport)
            != scale.base(pixelSize: windowPixels, in: viewport))
    }

    @Test("the margin a picture is drawn inside is counted once, not twice")
    func placingInsideAMargin() {
        // **The same two properties as ``placingKeepsThePictureStill()``, at a scale whose base is
        // not 1.** Everything above runs portrait, where the picture is drawn at its own fit and
        // the base is 1 — and a division by 1 does nothing, so a base divided out twice reads as
        // correct. Held sideways the chrome keeps a margin and the base is 0.75, where a window
        // opened from a tile landed a quarter too large and then shrank into place over the rest
        // of the movement. This is the test that would have said so.
        let viewport = sideways
        let scale = PictureScale(scalesToFill: false, inset: ChromeMetricsProbe.pictureInset)
        let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        let base = scale.base(pixelSize: windowPixels, in: viewport)
        // Worth nothing unless the base is somewhere a division by it changes the answer.
        #expect(abs(base - 1) > 0.1)

        // Placed on its own rest rectangle, the answer is the rest state.
        let rest = scale.scaled(
            CanvasGeometry.videoRect(bounds: viewport, pixelSize: windowPixels),
            in: viewport,
            by: base
        )
        guard let atRest = MosaicZoom.placing(
            pixelSize: windowPixels, anchor: full, at: rest,
            bounds: viewport, scale: scale
        ) else {
            Issue.record("the picture can be placed on its rest rectangle")
            return
        }
        #expect(abs(atRest.zoom - 1) < 0.001)

        // And drawn at the answer, it occupies exactly the rectangle it was aimed at. The target
        // carries the window's own shape, or the placement is the larger of two ratios and lands
        // covering it on one axis and overflowing on the other.
        let midway = CGRect(
            x: 300, y: 100, width: 260,
            height: 260 * windowPixels.height / windowPixels.width
        )
        guard let placed = MosaicZoom.placing(
            pixelSize: windowPixels, anchor: full, at: midway,
            bounds: viewport, scale: scale
        ), let drawn = CanvasGeometry.rect(
            normalized: full, bounds: viewport, pixelSize: windowPixels,
            zoom: base * placed.zoom, pan: placed.pan
        ) else {
            Issue.record("the picture can be placed on a rectangle")
            return
        }
        #expect(close(drawn, midway, within: 1))
    }
}

/// The chrome's own margin, restated for the tests so they do not depend on a view target.
///
/// It is the app's number rather than the kit's — see `ChromeMetrics.pictureInset` — and the
/// value here only has to be one the arithmetic works at.
enum ChromeMetricsProbe {
    static let pictureInset: CGFloat = 0.125
}
