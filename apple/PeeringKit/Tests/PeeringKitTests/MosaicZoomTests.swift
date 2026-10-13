import CoreGraphics
import RemoteCore
import Testing

@testable import PeeringKit

@Suite("The movement between an arrangement and one of its windows")
struct MosaicZoomTests {
    private let sideways = CGSize(width: 852, height: 393)
    private let upright = CGSize(width: 393, height: 852)

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

    private let windowPixels = CGSize(width: 1512, height: 982)

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
        // The movement must end where the window's own stream starts, or the picture moves again on arrival.
        for viewport in [sideways, upright] {
            for count in [2, 4, 6, 9] {
                for scalesToFill in [false, true] {
                    let layout = layout(count: count, viewport: viewport)
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

                        guard let end = CanvasGeometry.rect(
                            normalized: layout.tiles[index].rect,
                            bounds: viewport, pixelSize: layout.canvas,
                            zoom: current * target.zoom, pan: target.pan
                        ).flatMap({ tile in MosaicTileFit.windowRect(sourceSize: windowPixels, in: tile) })
                        else {
                            Issue.record("the tile's window has a rectangle")
                            return
                        }

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
        // Degenerate-pair guard: a window of the tile's own aspect never letterboxes, so use a real portrait tap.
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

                        guard let end = drawn(
                            pixelSize: windowPixels, bounds: viewport,
                            zoom: rest * target.zoom, pan: target.pan
                        ) else {
                            Issue.record("the window has a rectangle")
                            return
                        }

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
        // Source and target must share a shape, or the transform takes the larger of two ratios and overflows.
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
            let destination = CanvasGeometry.videoRect(bounds: viewport, pixelSize: windowPixels)

            #expect(abs(window.width / window.height - windowAspect) < 0.001)
            #expect(abs(destination.width / destination.height - windowAspect) < 0.001)
        }
    }

    @Test("a picture put where a movement has it is drawn exactly there")
    func placingKeepsThePictureStill() {
        // A stream arriving mid-movement must not be read through the movement's state: solve for the state so the picture stays still.
        let viewport = upright
        let layout = layout(count: 4, viewport: viewport)
        let scale = PictureScale(scalesToFill: false, inset: 0)
        let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

        let midway = CGRect(x: 60, y: 320, width: 270, height: 175)
        guard let placed = MosaicZoom.placing(
            pixelSize: windowPixels, anchor: full, at: midway,
            bounds: viewport, scale: scale
        ) else {
            Issue.record("the picture can be placed on a rectangle")
            return
        }

        guard let drawn = CanvasGeometry.rect(
            normalized: full, bounds: viewport, pixelSize: windowPixels,
            zoom: scale.base(pixelSize: windowPixels, in: viewport) * placed.zoom,
            pan: placed.pan
        ) else {
            Issue.record("the window has a rectangle")
            return
        }
        #expect(close(drawn, midway, within: 1))

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
        // Guessing zooms until the tile covers the screen, then the reset pulls it back.
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

        #expect(MosaicZoom.returning(
            layout: layout, sourceID: CaptureSource.window(999).stableID, sourceSize: windowPixels,
            bounds: viewport, effectiveZoom: 1, pan: .zero, scale: scale
        ) == nil)
    }

    @Test("Fill is a different scale for a canvas than for one of its windows")
    func fillDiffersByPicture() {
        // Aiming at the canvas fill leaves the window wrongly sized until the stream arrives.
        let viewport = upright
        let layout = layout(count: 4, viewport: viewport)
        let scale = PictureScale(scalesToFill: true, inset: 0)

        #expect(scale.base(pixelSize: layout.canvas, in: viewport)
            != scale.base(pixelSize: windowPixels, in: viewport))
    }

    @Test("the margin a picture is drawn inside is counted once, not twice")
    func placingInsideAMargin() {
        // Same properties at base scale 0.75 (landscape chrome margin): at base 1 a base divided out twice reads as correct.
        let viewport = sideways
        let scale = PictureScale(scalesToFill: false, inset: ChromeMetricsProbe.pictureInset)
        let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        let base = scale.base(pixelSize: windowPixels, in: viewport)
        #expect(abs(base - 1) > 0.1)

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

        // The target carries the window's shape, or the placement overflows on one axis.
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

enum ChromeMetricsProbe {
    static let pictureInset: CGFloat = 0.125
}
