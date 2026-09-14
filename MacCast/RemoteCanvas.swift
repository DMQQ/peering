import RemoteCore
import SwiftUI
import UIKit

/// The gesture surface over the video.
///
/// UIKit rather than SwiftUI gestures, for two reasons that are both about the pointer:
///
/// - SwiftUI's `DragGesture` reports one touch and has no notion of *how many* fingers are
///   down, so "one finger drives the pointer, two fingers scroll" — the distinction every
///   remote desktop client makes — cannot be expressed with it at all.
/// - A SwiftUI gesture's value is delivered through a view update, which means a cursor move
///   waits for a layout pass. On a 120 Hz display that is the difference between tracking the
///   finger and trailing it.
struct CanvasGestureView: UIViewRepresentable {
    /// One finger, in the canvas's coordinate space.
    var onTouchDown: (CGPoint) -> Void
    var onTouchMove: (CGPoint) -> Void
    var onTouchUp: (CGPoint) -> Void
    /// Two-finger tap.
    var onSecondaryClick: (CGPoint) -> Void
    /// Two-finger drag: an incremental translation.
    var onScroll: (CGSize) -> Void
    /// Pinch: an incremental scale factor and the point it is centred on.
    var onZoom: (CGFloat, CGPoint) -> Void
    /// Two-finger drag with the canvas pinned instead of scrolled, for panning a zoomed view.
    var onPanCanvas: (CGSize) -> Void
    /// Whether a two-finger drag pans the canvas rather than scrolling the Mac. The client
    /// flips this on once the view is zoomed, where moving the view is what the gesture is
    /// for — and off when it is not, where the Mac's scroll is.
    var twoFingerPansCanvas: Bool

    func makeUIView(context: Context) -> GestureSurfaceView {
        let view = GestureSurfaceView()
        view.twoFingerPansCanvas = twoFingerPansCanvas
        view.handlers = .init(
            onTouchDown: onTouchDown,
            onTouchMove: onTouchMove,
            onTouchUp: onTouchUp,
            onSecondaryClick: onSecondaryClick,
            onScroll: onScroll,
            onZoom: onZoom,
            onPanCanvas: onPanCanvas
        )
        return view
    }

    func updateUIView(_ view: GestureSurfaceView, context: Context) {
        // The closures capture the current view state (zoom, pan, canvas size), so they are
        // replaced on every update rather than captured once in `makeUIView`.
        view.twoFingerPansCanvas = twoFingerPansCanvas
        view.handlers = .init(
            onTouchDown: onTouchDown,
            onTouchMove: onTouchMove,
            onTouchUp: onTouchUp,
            onSecondaryClick: onSecondaryClick,
            onScroll: onScroll,
            onZoom: onZoom,
            onPanCanvas: onPanCanvas
        )
    }
}

/// The view behind ``CanvasGestureView``.
final class GestureSurfaceView: UIView {
    struct Handlers {
        var onTouchDown: (CGPoint) -> Void
        var onTouchMove: (CGPoint) -> Void
        var onTouchUp: (CGPoint) -> Void
        var onSecondaryClick: (CGPoint) -> Void
        var onScroll: (CGSize) -> Void
        var onZoom: (CGFloat, CGPoint) -> Void
        var onPanCanvas: (CGSize) -> Void
    }

    var handlers: Handlers?

    /// Whether two fingers scroll or pan the canvas. The client toggles this: once zoomed in,
    /// the same gesture is much more useful for moving the view than for scrolling the Mac.
    var twoFingerPansCanvas = false {
        didSet { twoFingerPan.minimumNumberOfTouches = 2 }
    }

    private lazy var oneFingerPan: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleOneFingerPan))
        // Exactly one touch. A second finger makes this fail rather than silently continuing
        // with whichever touch the recogniser happened to keep, which would leave the Mac's
        // left button held down while the user thinks they are scrolling.
        gesture.minimumNumberOfTouches = 1
        gesture.maximumNumberOfTouches = 1
        return gesture
    }()

    private lazy var oneFingerTap: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        gesture.numberOfTouchesRequired = 1
        return gesture
    }()

    private lazy var twoFingerPan: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan))
        gesture.minimumNumberOfTouches = 2
        gesture.maximumNumberOfTouches = 2
        return gesture
    }()

    private lazy var twoFingerTap: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
        gesture.numberOfTouchesRequired = 2
        return gesture
    }()

    private lazy var pinch: UIPinchGestureRecognizer = {
        UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        addGestureRecognizer(oneFingerPan)
        addGestureRecognizer(twoFingerPan)
        addGestureRecognizer(pinch)
        addGestureRecognizer(twoFingerTap)
        addGestureRecognizer(oneFingerTap)

        // A tap must not be recognised in the middle of a drag, and a two-finger tap must not
        // fire at the end of a two-finger scroll. Both are "the gesture that moved wins".
        oneFingerTap.require(toFail: oneFingerPan)
        twoFingerTap.require(toFail: twoFingerPan)
        twoFingerTap.require(toFail: pinch)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - One finger: the pointer

    @objc private func handleOneFingerPan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            // The press is posted *after* the move, and the ordering is load-bearing on the
            // host: `mouseDown` is injected at the position of the last move it saw, so a
            // click that overtook its own move would land wherever the cursor happened to be.
            handlers?.onTouchDown(point)
        case .changed:
            handlers?.onTouchMove(point)
        case .ended, .cancelled, .failed:
            handlers?.onTouchUp(point)
        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        handlers?.onTouchDown(point)
        handlers?.onTouchUp(point)
    }

    // MARK: - Two fingers

    @objc private func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.translation(in: self)
        // Incremental, and the recogniser's accumulator is reset each time so the next
        // callback reports only what moved since. Re-sending the cumulative translation would
        // make the scroll accelerate away under the user's fingers.
        gesture.setTranslation(.zero, in: self)

        guard point != .zero else { return }
        // A translation is a displacement, not a position: both axes are signed and neither
        // has an origin, which is what `CGSize` means here and `CGPoint` would misdescribe.
        let translation = CGSize(width: point.x, height: point.y)
        if twoFingerPansCanvas {
            handlers?.onPanCanvas(translation)
        } else {
            handlers?.onScroll(translation)
        }
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        handlers?.onSecondaryClick(gesture.location(in: self))
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        let scale = gesture.scale
        gesture.scale = 1
        guard scale != 1 else { return }
        handlers?.onZoom(scale, gesture.location(in: self))
    }
}

/// Where the video is actually drawn inside the canvas.
///
/// The layer letterboxes with `videoGravity = .resizeAspect`, so the picture occupies a
/// centred rect whose aspect matches the *captured pixels*. Every touch has to be mapped
/// through that rect, or the pointer lands proportionally wrong the moment the two aspects
/// differ — which on a phone showing a 16:10 Mac display is always.
enum CanvasGeometry {
    /// The layer's letterboxed rect for a captured size, inside `bounds`.
    static func videoRect(bounds: CGSize, pixelSize: CGSize?) -> CGRect {
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0,
              bounds.width > 0, bounds.height > 0
        else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / pixelSize.width, bounds.height / pixelSize.height)
        let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Turns a touch into a normalized position, undoing the canvas's zoom and pan first.
    ///
    /// Normalized — never pixels. The host maps the result through its own transform, which
    /// is the only side that knows where the captured content sits in the Mac's global
    /// coordinate space, and which changes under it when a window moves or a display is
    /// switched. A client that sent pixels would be wrong the first time either happened.
    static func normalized(
        point: CGPoint,
        bounds: CGSize,
        pixelSize: CGSize?,
        zoom: CGFloat,
        pan: CGSize
    ) -> NormalizedPoint? {
        guard bounds.width > 0, bounds.height > 0, zoom > 0 else { return nil }
        let rect = videoRect(bounds: bounds, pixelSize: pixelSize)
        guard rect.width > 0, rect.height > 0 else { return nil }

        let centre = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        let content = CGPoint(
            x: (point.x - centre.x - pan.width) / zoom + centre.x,
            y: (point.y - centre.y - pan.height) / zoom + centre.y
        )

        let x = (content.x - rect.minX) / rect.width
        let y = (content.y - rect.minY) / rect.height
        // Clamped rather than rejected. A finger that slides off the edge of a letterboxed
        // picture has still expressed "as far as possible in that direction", and dropping
        // the sample would make the cursor stall at the boundary while the finger keeps
        // moving — which reads as a broken connection rather than as a limit.
        return NormalizedPoint(x: Double(min(max(x, 0), 1)), y: Double(min(max(y, 0), 1)))
    }
}
