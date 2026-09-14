import CoreGraphics
import Testing

@testable import RemoteCore

@Suite("InputTransform")
struct InputTransformTests {
    /// A 2560×1440 Retina display at the primary origin.
    private let primary = InputTransform(
        origin: .zero,
        pixelSize: CGSize(width: 2560, height: 1440),
        pointPixelScale: 2
    )

    @Test("maps normalized centre to the middle of the display in points")
    func centreOfPrimary() {
        let point = primary.globalPoint(fromNormalized: NormalizedPoint(x: 0.5, y: 0.5))
        // 2560 px / 2 = 1280 pt wide, so the centre is at 640 pt.
        #expect(point.x == 640)
        #expect(point.y == 360)
    }

    @Test("maps the corners exactly")
    func corners() {
        #expect(primary.globalPoint(fromNormalized: NormalizedPoint(x: 0, y: 0)) == .zero)

        let bottomRight = primary.globalPoint(fromNormalized: NormalizedPoint(x: 1, y: 1))
        #expect(bottomRight.x == 1280)
        #expect(bottomRight.y == 720)
    }

    /// The Retina trap: `SCDisplay.width` reports points, so using it instead of real
    /// pixel dimensions makes the cursor land at half the distance on a Retina panel.
    @Test("accounts for the point/pixel scale")
    func retinaScaling() {
        let nonRetina = InputTransform(
            origin: .zero,
            pixelSize: CGSize(width: 2560, height: 1440),
            pointPixelScale: 1
        )
        let retinaPoint = primary.globalPoint(fromNormalized: NormalizedPoint(x: 0.5, y: 0.5))
        let plainPoint = nonRetina.globalPoint(fromNormalized: NormalizedPoint(x: 0.5, y: 0.5))
        #expect(plainPoint.x == 2 * retinaPoint.x)
    }

    /// A display arranged to the left of the primary has a negative origin, and that has
    /// to survive into the injected coordinate or clicks land on the wrong screen.
    @Test("preserves a negative display origin")
    func secondaryDisplayToTheLeft() {
        let left = InputTransform(
            origin: CGPoint(x: -1920, y: 0),
            pixelSize: CGSize(width: 1920, height: 1080),
            pointPixelScale: 1
        )
        #expect(left.globalPoint(fromNormalized: NormalizedPoint(x: 0, y: 0)).x == -1920)
        #expect(left.globalPoint(fromNormalized: NormalizedPoint(x: 1, y: 0)).x == 0)
    }

    /// A client canvas can overscroll mid-gesture; an out-of-range value must not drive
    /// the host cursor off the captured area.
    @Test("clamps out-of-range normalized input")
    func clamping() {
        // (-5, 9) clamps to (0, 1): the left edge, bottom edge — not the origin.
        let overscrolled = primary.globalPoint(fromNormalized: NormalizedPoint(x: -5, y: 9))
        #expect(overscrolled.x == 0)
        #expect(overscrolled.y == 720)

        let clamped = primary.globalPoint(fromNormalized: NormalizedPoint(x: 1.5, y: 1.5))
        #expect(clamped.x == 1280)
        #expect(clamped.y == 720)
    }

    /// A window's content moves and resizes, so the transform is rebuilt against a
    /// non-zero origin and a size that is not the whole display.
    @Test("maps within a window's own content rect")
    func windowContentRect() {
        let window = InputTransform(
            origin: CGPoint(x: 300, y: 200),
            pixelSize: CGSize(width: 800, height: 600),
            pointPixelScale: 2
        )
        #expect(window.globalPoint(fromNormalized: NormalizedPoint(x: 0, y: 0)) == CGPoint(x: 300, y: 200))

        let centre = window.globalPoint(fromNormalized: NormalizedPoint(x: 0.5, y: 0.5))
        // 800 px / 2 = 400 pt wide, so half is 200 from a 300 pt origin = 500.
        // 600 px / 2 = 300 pt tall, so half is 150 from a 200 pt origin = 350.
        //
        // Written as plain literals deliberately: an arithmetic expression here is
        // evaluated by the `#expect` macro without the CGFloat type context and the
        // expectation then fails despite both sides printing the same number.
        #expect(centre.x == 500)
        #expect(centre.y == 350)
    }

    @Test("inverse mapping round-trips")
    func inverseRoundTrip() {
        for x in stride(from: 0.0, through: 1.0, by: 0.1) {
            for y in stride(from: 0.0, through: 1.0, by: 0.1) {
                let original = NormalizedPoint(x: x, y: y)
                let global = primary.globalPoint(fromNormalized: original)
                let recovered = primary.normalizedPoint(fromGlobal: global)
                #expect(abs(recovered.x - x) < 1e-9)
                #expect(abs(recovered.y - y) < 1e-9)
            }
        }
    }

    /// A transform built before the stream reports a real size must not divide by zero.
    @Test("survives a zero size or scale")
    func degenerateInputs() {
        let empty = InputTransform(origin: .zero, pixelSize: .zero, pointPixelScale: 0)
        #expect(empty.globalPoint(fromNormalized: NormalizedPoint(x: 0.5, y: 0.5)) == .zero)
        #expect(empty.normalizedPoint(fromGlobal: CGPoint(x: 10, y: 10)) == NormalizedPoint(x: 0, y: 0))
    }
}
