import CoreGraphics
import Testing

@testable import MacCastKit

@Suite("Fitting a window into one tile of an arrangement")
struct MosaicTileFitTests {
    /// A window of the shape most Mac windows are.
    private let window = CGSize(width: 1512, height: 982)
    /// A window nothing like it: a palette, a terminal, a phone-shaped sheet.
    private let tall = CGSize(width: 400, height: 800)

    @Test("the window keeps its own shape inside the tile, and is centred")
    func theWindowIsLetterboxedNotCropped() {
        let tile = CGRect(x: 100, y: 40, width: 588, height: 368)

        guard let rect = MosaicTileFit.windowRect(sourceSize: window, in: tile) else {
            Issue.record("a window in a tile has a rectangle")
            return
        }
        // Its own shape, to within the pixel the arithmetic rounds at.
        #expect(abs(rect.width / rect.height - window.width / window.height) < 0.001)
        #expect(abs(rect.midX - tile.midX) < 0.001)
        #expect(abs(rect.midY - tile.midY) < 0.001)
        // As large as the tile allows, on the axis that binds.
        #expect(abs(rect.height - tile.height) < 0.001)
        #expect(rect.width <= tile.width + 0.001)
    }

    @Test("a window taller than its slot is letterboxed, not squashed and not cropped")
    func aTallWindowKeepsItsShape() {
        let tile = CGRect(x: 0, y: 0, width: 588, height: 368)
        guard let rect = MosaicTileFit.windowRect(sourceSize: tall, in: tile) else {
            Issue.record("a tall window in a tile has a rectangle")
            return
        }
        #expect(abs(rect.width / rect.height - tall.width / tall.height) < 0.001)
        // The height is what binds for a window taller than its slot, and the width is what is
        // left over: a tile twice as wide as its window holds bars either side, not a crop.
        #expect(abs(rect.height - tile.height) < 0.001)
        #expect(rect.width < tile.width)
    }

    @Test("a window smaller than its slot is magnified to fill it")
    func aSmallWindowIsMagnified() {
        let tile = CGRect(x: 0, y: 0, width: 588, height: 368)
        let small = CGSize(width: 300, height: 200)
        guard let rect = MosaicTileFit.windowRect(sourceSize: small, in: tile) else {
            Issue.record("a small window in a tile has a rectangle")
            return
        }
        // Magnified until the tile binds on one axis, and its own shape kept on the other: a
        // window smaller than its slot fills the slot rather than sitting in the corner of it.
        #expect(abs(rect.height - tile.height) < 0.001)
        #expect(rect.width > small.width)
        #expect(rect.height > small.height)
    }

    @Test("nothing to place is no rectangle, rather than a rectangle of zeros")
    func degenerateSizesHaveNoAnswer() {
        #expect(MosaicTileFit.windowRect(sourceSize: .zero, in: CGRect(x: 0, y: 0, width: 10, height: 10)) == nil)
        #expect(MosaicTileFit.windowRect(sourceSize: CGSize(width: 10, height: 10), in: .zero) == nil)
        #expect(MosaicTileFit.surface(sourceSize: .zero, tilePixels: CGRect(x: 0, y: 0, width: 10, height: 10)) == nil)
    }

    @Test("the surface the Mac captures has the window's own shape")
    func theSurfaceHasTheWindowsShape() {
        let tile = CGRect(x: 0, y: 0, width: 588, height: 368)
        guard let surface = MosaicTileFit.surface(sourceSize: tall, tilePixels: tile) else {
            Issue.record("a tall window in a tile has a surface")
            return
        }
        // **The property the crop was breaking.** Whatever the tile's shape, the surface the
        // capture is built at is the window's shape, so ScreenCaptureKit has nothing to choose
        // between cropping and letterboxing, and what arrives is the window.
        #expect(abs(surface.width / surface.height - tall.width / tall.height) < 0.02)
        #expect(surface.width <= tall.width + 0.001)
        #expect(surface.height <= tall.height + 0.001)
    }

    @Test("a surface is even on both axes, which is what the encoder expects")
    func surfacesAreEven() {
        for source in [window, tall, CGSize(width: 333, height: 777), CGSize(width: 1281, height: 721)] {
            let tile = CGRect(x: 0, y: 0, width: 587, height: 369)
            guard let surface = MosaicTileFit.surface(sourceSize: source, tilePixels: tile) else {
                Issue.record("a window in an odd tile has a surface")
                return
            }
            #expect(surface.width.truncatingRemainder(dividingBy: 2) == 0)
            #expect(surface.height.truncatingRemainder(dividingBy: 2) == 0)
            #expect(surface.width >= 2)
            #expect(surface.height >= 2)
        }
    }

    @Test("the surface fills exactly the rectangle the phone draws the window in")
    func theSurfaceAndThePhoneAgree() {
        // **The agreement this type exists for, and it is checked by running both halves.** The
        // Mac's compositor draws the captured surface into the tile with the larger scale that
        // fits it — `MosaicCompositor.place`, whose arithmetic is the four lines below — and the
        // phone draws the window with `windowRect`. A window whose surface is narrower than its
        // tile, drawn by one rule and described by the other, is the misaimed zoom.
        for source in [window, tall, CGSize(width: 300, height: 200), CGSize(width: 2000, height: 1200)] {
            for tile in [
                CGRect(x: 0, y: 0, width: 588, height: 368),
                CGRect(x: 0, y: 0, width: 380, height: 400),
                CGRect(x: 0, y: 0, width: 900, height: 300),
            ] {
                guard let surface = MosaicTileFit.surface(sourceSize: source, tilePixels: tile),
                      let phone = MosaicTileFit.windowRect(sourceSize: source, in: tile)
                else {
                    Issue.record("a window in \(tile.size) has both a surface and a rectangle")
                    return
                }

                let scale = min(tile.width / surface.width, tile.height / surface.height)
                let drawn = CGRect(
                    x: tile.minX + (tile.width - surface.width * scale) / 2,
                    y: tile.minY + (tile.height - surface.height * scale) / 2,
                    width: surface.width * scale,
                    height: surface.height * scale
                )

                // Within a couple of points, which is all the even-rounding of the surface costs:
                // it is the one place the two ends are allowed to disagree, and it is why the
                // surface is rounded to the nearest even rather than down to it.
                #expect(abs(drawn.midX - phone.midX) < 2)
                #expect(abs(drawn.midY - phone.midY) < 2)
                #expect(abs(drawn.width - phone.width) < 2)
                #expect(abs(drawn.height - phone.height) < 2)
            }
        }
    }
}
