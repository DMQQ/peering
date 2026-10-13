import CoreGraphics
import Testing

@testable import PeeringKit

@Suite("The zoom and pan rules of the remote picture")
struct CanvasViewportTests {
    private let canvas = CGSize(width: 852, height: 393)
    private let fitted = CGSize(width: 698, height: 393)

    @Test("A rail down one edge counts from that edge, not from the opposite one")
    func railMeasuredFromItsOwnEdge() {
        let rail = CGRect(x: 0, y: 0, width: 121, height: 393)
        let margin = CanvasViewport.chromeMargin([rail], canvas: canvas, gap: 16)
        #expect(margin.width == 16)
        #expect(margin.height == 16)
    }

    @Test("A rail inset from its edge counts its distance from that edge")
    func insetRailCountsItsInset() {
        let rail = CGRect(x: 59, y: 0, width: 62, height: 393)
        let margin = CanvasViewport.chromeMargin([rail], canvas: canvas, gap: 16)
        #expect(margin.width == 75)
    }

    @Test("The thickest piece of chrome sets the margin")
    func thickestChromeWins() {
        let left = CGRect(x: 100, y: 0, width: 40, height: 393)
        let top = CGRect(x: 0, y: 20, width: 852, height: 44)
        let margin = CanvasViewport.chromeMargin([left, top], canvas: canvas, gap: 10)
        #expect(margin.width == 110)
        #expect(margin.height == 30)
    }

    @Test("No canvas, no margin")
    func emptyCanvasHasNoMargin() {
        let rail = CGRect(x: 0, y: 0, width: 50, height: 50)
        #expect(CanvasViewport.chromeMargin([rail], canvas: .zero, gap: 16) == .zero)
    }

    @Test("A fitted picture cannot be dragged on the axis it fits")
    func fittedPictureStaysPut() {
        let limit = CanvasViewport.panLimit(
            canvas: canvas, picture: fitted, effectiveZoom: 1, margin: CGSize(width: 16, height: 16)
        )
        #expect(limit.height == 0)
        #expect(limit.width == 0)
    }

    @Test("A thick margin is the floor while the overscroll is still small")
    func marginIsTheFloor() {
        let limit = CanvasViewport.panLimit(
            canvas: canvas, picture: fitted, effectiveZoom: 1.1, margin: CGSize(width: 150, height: 150)
        )
        let slack = (fitted.height * 1.1 - canvas.height) / 2
        #expect(abs(limit.height - (slack + 150)) < 0.0001)
    }

    @Test("A picture narrower than the canvas can still be dragged once zoomed in")
    func narrowAxisMovesBeforeItOverflows() {
        let limit = CanvasViewport.panLimit(
            canvas: canvas, picture: fitted, effectiveZoom: 1.2, margin: .zero
        )
        #expect(fitted.width * 1.2 < canvas.width)
        #expect(abs(limit.width - canvas.width * 0.5 * 0.4) < 0.0001)
    }

    @Test("By 1.5x a corner of the picture can be brought to the middle of the screen")
    func cornerReachesTheMiddleByOneAndAHalf() {
        let limit = CanvasViewport.panLimit(
            canvas: canvas, picture: fitted, effectiveZoom: 1.5, margin: CGSize(width: 16, height: 16)
        )
        #expect(abs(limit.width - fitted.width * 1.5 / 2) < 0.0001)
        #expect(abs(limit.height - fitted.height * 1.5 / 2) < 0.0001)
    }

    @Test("Further zoom never lets a corner past the middle")
    func cornerStopsAtTheMiddle() {
        let limit = CanvasViewport.panLimit(
            canvas: canvas, picture: fitted, effectiveZoom: 6, margin: CGSize(width: 500, height: 500)
        )
        #expect(limit.width == fitted.width * 6 / 2)
        #expect(limit.height == fitted.height * 6 / 2)
    }

    @Test("The overscroll grows from nothing at 1x to its full size at 1.5x")
    func overscrollRamps() {
        let slack = { (zoom: CGFloat) in (self.fitted.height * zoom - self.canvas.height) / 2 }
        let partway = CanvasViewport.panLimit(
            canvas: canvas, picture: fitted, effectiveZoom: 1.25, margin: .zero
        )
        #expect(abs(partway.height - (slack(1.25) + canvas.height / 4)) < 0.0001)
    }

    @Test("Below fit the picture keeps a little travel that shrinks with the zoom")
    func underfitTravel() {
        let atHalf = CanvasViewport.panLimit(
            canvas: canvas, picture: fitted, effectiveZoom: 0.5, margin: .zero
        )
        #expect(atHalf == CGSize(width: 80, height: 80))
        let atFit = CanvasViewport.panLimit(
            canvas: canvas, picture: fitted, effectiveZoom: 1, margin: .zero
        )
        #expect(atFit == .zero)
    }

    @Test("Clamping holds a pan inside the limit on each side")
    func clampingIsSymmetric() {
        let limit = CGSize(width: 50, height: 20)
        #expect(CanvasViewport.clamped(CGSize(width: 90, height: -90), to: limit)
            == CGSize(width: 50, height: -20))
        #expect(CanvasViewport.clamped(CGSize(width: 10, height: 5), to: limit)
            == CGSize(width: 10, height: 5))
    }

    @Test("A pinch keeps the point under the fingers where it was")
    func pinchAnchorsOnFingers() {
        let centre = CGPoint(x: 600, y: 100)
        let result = CanvasViewport.pinched(
            zoom: 1, pan: .zero, factor: 2, centre: centre, canvas: canvas
        )
        #expect(result.zoom == 2)
        #expect(result.pan == CGSize(
            width: (centre.x - canvas.width / 2) * -1,
            height: (centre.y - canvas.height / 2) * -1
        ))
    }

    @Test("A pinch against the limit neither zooms nor slides the picture")
    func pinchAtTheLimitDoesNotSlide() {
        let pan = CGSize(width: 30, height: 12)
        let result = CanvasViewport.pinched(
            zoom: CanvasViewport.maximumZoom,
            pan: pan,
            factor: 1.5,
            centre: CGPoint(x: 700, y: 50),
            canvas: canvas
        )
        #expect(result.zoom == CanvasViewport.maximumZoom)
        #expect(result.pan == pan)
    }

    @Test("The zoom stays inside its range")
    func zoomRange() {
        #expect(CanvasViewport.clampedZoom(0.1) == 1)
        #expect(CanvasViewport.clampedZoom(20) == 8)
        #expect(CanvasViewport.clampedZoom(3) == 3)
        #expect(CanvasViewport.wheeled(zoom: 7, step: -2) == 8)
        #expect(CanvasViewport.wheeled(zoom: 1, step: 0) == 1)
    }

    @Test("The wheel reads 0 at the minimum and 1 at the maximum")
    func wheelEnds() {
        #expect(CanvasViewport.wheelPosition(zoom: 1) == 0)
        #expect(CanvasViewport.wheelPosition(zoom: 8) == 1)
        #expect(CanvasViewport.wheelPosition(zoom: 0) == 0)
        let middle = CanvasViewport.wheelPosition(zoom: 2)
        #expect(middle > 0.3 && middle < 0.6)
    }
}
