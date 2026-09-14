import RemoteCore
import SwiftUI
import UIKit

/// What the fingers on the picture are for.
///
/// A choice the user makes and can see, not a heuristic. It used to be a hidden flag that
/// pinch-zoom flipped on its own, so the same two-finger drag either scrolled the Mac or moved
/// the view depending on something the user had done earlier in a different gesture — which is
/// impossible to build a habit around.
enum InteractionMode: String, CaseIterable, Identifiable {
    /// Fingers drive the Mac: tap and drag are the pointer, two fingers scroll it.
    case control
    /// Fingers drive the picture: drag pans, pinch zooms, and nothing reaches the Mac.
    case navigate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .control: return "View & scroll"
        case .navigate: return "Drag & zoom"
        }
    }

    var symbol: String {
        switch self {
        case .control: return "hand.point.up.left"
        case .navigate: return "arrow.up.left.and.arrow.down.right"
        }
    }

    var toggled: InteractionMode { self == .control ? .navigate : .control }
}

extension InteractionMode {
    /// Whether a one-finger drag moves the picture rather than the Mac's pointer.
    var oneFingerDragPansCanvas: Bool { self == .navigate }

    /// Whether a two-finger drag moves the picture rather than scrolling the Mac.
    ///
    /// True only in drag & zoom. Zooming in no longer changes this: an explicit mode that
    /// silently behaves like the other one is the thing this replaced.
    var twoFingerDragPansCanvas: Bool { self == .navigate }

    /// Whether a tap is a click on the Mac. False in drag & zoom, where a tap is nothing at all
    /// — the mode exists so the picture can be moved and inspected without anything landing on
    /// the Mac by accident.
    var tapsReachTheMac: Bool { self == .control }

    /// Whether a pinch resizes the picture. Drag & zoom only.
    ///
    /// Scaling the view is a way of *looking* at the Mac, so it belongs with the mode that is
    /// only about looking. Allowed in view & scroll, a pinch mid-session silently rescaled the
    /// canvas — and every click after it is mapped through that scale, so the pointer landed
    /// somewhere the user never aimed at.
    var pinchZoomsCanvas: Bool { self == .navigate }
}

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
    /// A drag that moves the picture instead of the Mac: one finger or two, in drag & zoom.
    var onPanCanvas: (CGSize) -> Void
    /// The exact bounds UIKit uses for gesture locations.
    var onSizeChange: (CGSize) -> Void
    /// Whether the fingers drive the Mac or the picture. See ``InteractionMode``.
    var interactionMode: InteractionMode
    /// The window's own chrome, in the canvas's coordinates. See ``CanvasGeometry/isBlocked``.
    var blockedRegions: [CGRect] = []
    /// Whether a floating panel is open. A tap on the picture then closes it instead of clicking
    /// the Mac — see ``GestureSurfaceView/handleTap(_:)``.
    var isPanelOpen: Bool = false
    /// Called when such a tap lands.
    var onDismissPanel: () -> Void = {}

    func makeUIView(context: Context) -> GestureSurfaceView {
        let view = GestureSurfaceView()
        view.interactionMode = interactionMode
        view.blockedRegions = blockedRegions
        view.isPanelOpen = isPanelOpen
        view.onDismissPanel = onDismissPanel
        view.handlers = .init(
            onTouchDown: onTouchDown,
            onTouchMove: onTouchMove,
            onTouchUp: onTouchUp,
            onSecondaryClick: onSecondaryClick,
            onScroll: onScroll,
            onZoom: onZoom,
            onPanCanvas: onPanCanvas,
            onSizeChange: onSizeChange
        )
        return view
    }

    func updateUIView(_ view: GestureSurfaceView, context: Context) {
        // The closures capture the current view state (zoom, pan, canvas size), so they are
        // replaced on every update rather than captured once in `makeUIView`.
        view.interactionMode = interactionMode
        view.blockedRegions = blockedRegions
        view.isPanelOpen = isPanelOpen
        view.onDismissPanel = onDismissPanel
        view.handlers = .init(
            onTouchDown: onTouchDown,
            onTouchMove: onTouchMove,
            onTouchUp: onTouchUp,
            onSecondaryClick: onSecondaryClick,
            onScroll: onScroll,
            onZoom: onZoom,
            onPanCanvas: onPanCanvas,
            onSizeChange: onSizeChange
        )
    }
}

/// The view behind ``CanvasGestureView``.
final class GestureSurfaceView: UIView, UIGestureRecognizerDelegate {
    struct Handlers {
        var onTouchDown: (CGPoint) -> Void
        var onTouchMove: (CGPoint) -> Void
        var onTouchUp: (CGPoint) -> Void
        var onSecondaryClick: (CGPoint) -> Void
        var onScroll: (CGSize) -> Void
        var onZoom: (CGFloat, CGPoint) -> Void
        var onPanCanvas: (CGSize) -> Void
        var onSizeChange: (CGSize) -> Void
    }

    var handlers: Handlers?

    /// Whether the fingers drive the Mac or the picture. Read by every handler below.
    var interactionMode: InteractionMode = .control {
        didSet { applyTouchLimit() }
    }

    /// How many touches a one-finger drag is allowed to survive.
    ///
    /// Raised to two in drag & zoom, and that is not a relaxation of the rule below so much as
    /// the point of the mode. A pinch and the drag that follows it are one continuous motion, and
    /// a recogniser that has already *failed* cannot pick the remaining finger back up until
    /// every touch has lifted — which is why moving a zoomed picture felt like it needed two
    /// fingers when one is plainly enough.
    ///
    /// The strict limit stays in view & scroll. There a second finger has to *end* the drag: the
    /// gesture is holding the Mac's mouse button down, and carrying on with whichever touch
    /// happened to survive would leave the button pressed while the user thinks they are
    /// scrolling.
    private func applyTouchLimit() {
        oneFingerPan.maximumNumberOfTouches = interactionMode == .navigate ? 2 : 1
    }

    /// Where the window's own chrome is, in this view's coordinates. A touch that starts inside
    /// one of these belongs to a button and is never sent to the Mac.
    var blockedRegions: [CGRect] = []

    /// Whether a floating panel is open, and what to do when a tap lands outside it.
    ///
    /// A panel is modal in intent but not in shape: it covers a corner of the picture and the
    /// rest of the screen is still the Mac. Without this, the only way to put one away is the
    /// button that opened it — which is a second target for a gesture the user has already made.
    var isPanelOpen = false
    var onDismissPanel: (() -> Void)?

    /// Set when a gesture began over the chrome, and cleared when it ends.
    ///
    /// Latched for the life of the gesture rather than re-tested each sample: a finger that
    /// starts on a button and slides off it is still pressing that button, and handing the drag
    /// to the Mac the moment it crossed the chrome's edge would be the same bug in a new place.
    private var ignoresCurrentGesture = false

    /// The same latch for the two-finger family, which has its own began/ended cycle.
    private var ignoresTwoFingerGesture = false

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

    private var lastReportedSize: CGSize = .zero

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

        // Pinch and two-finger pan must fire at the same time so the user can zoom-and-reposition
        // in one gesture. Without this, iOS picks whichever started first and cancels the other,
        // which makes the view jump as soon as the user shifts the pinch centroid.
        pinch.delegate = self
        twoFingerPan.delegate = self

        // The recogniser is lazy, so its touch limit is set here rather than in its own
        // definition — the mode it depends on is not known until the view exists.
        applyTouchLimit()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Only allow pinch + two-finger pan to coexist; everything else remains exclusive.
        let pair: Set<UIGestureRecognizer> = [pinch, twoFingerPan]
        return pair.contains(gestureRecognizer) && pair.contains(other)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size != lastReportedSize else { return }
        lastReportedSize = size
        // Deferring avoids mutating SwiftUI state in the middle of UIKit's layout pass.
        DispatchQueue.main.async { [weak self] in
            self?.handlers?.onSizeChange(size)
        }
    }

    // MARK: - One finger: the pointer

    @objc private func handleOneFingerPan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)

        let isEnding = gesture.state == .ended
            || gesture.state == .cancelled
            || gesture.state == .failed
        if gesture.state == .began {
            ignoresCurrentGesture = CanvasGeometry.isBlocked(point, regions: blockedRegions)
        }
        defer { if isEnding { ignoresCurrentGesture = false } }
        guard !ignoresCurrentGesture else { return }

        if interactionMode.oneFingerDragPansCanvas {
            // Incremental, and the accumulator is reset each time, for the same reason the
            // two-finger handler does it: a cumulative translation would make the view
            // accelerate away from the finger. Reset before the guard below as well, so the
            // travel of a two-finger stretch is thrown away rather than landing in one jump when
            // the second finger lifts.
            let moved = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            // Two fingers are the pinch's. Ignored rather than failed, both so the picture does
            // not jump to follow a centroid the user meant as a zoom, and so the finger left
            // behind when the pinch ends goes on panning.
            guard gesture.numberOfTouches <= 1 else { return }
            guard moved != .zero else { return }
            handlers?.onPanCanvas(CGSize(width: moved.x, height: moved.y))
            return
        }

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
        // Checked *before* the mode guard below, because a mode that makes taps inert on the Mac
        // is not a mode that makes them inert on this app's own chrome. A panel that could only
        // be dismissed in one of the two modes would be a bug the user has to discover.
        //
        // Blocked points are excluded so the panel's own buttons still work: a tap inside one
        // belongs to that button, and dismissing on it would close the panel out from under the
        // tile the user was aiming at.
        if CanvasGeometry.dismissesPanel(at: point, regions: blockedRegions, isPanelOpen: isPanelOpen) {
            onDismissPanel?()
            return
        }
        // Nothing at all in drag & zoom, which is the point of that mode: the picture can be
        // moved and inspected without a stray tap landing on whatever is under it.
        guard interactionMode.tapsReachTheMac else { return }
        guard !CanvasGeometry.isBlocked(point, regions: blockedRegions) else { return }
        handlers?.onTouchDown(point)
        handlers?.onTouchUp(point)
    }

    // MARK: - Two fingers

    @objc private func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
        // Two fingers that land on the chrome are scrolling a panel — the macro strip, the
        // desktop thumbnails — and must not also scroll the Mac behind it.
        if gesture.state == .began {
            let start = gesture.location(in: self)
            ignoresTwoFingerGesture = CanvasGeometry.isBlocked(start, regions: blockedRegions)
        }
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            ignoresTwoFingerGesture = false
        }
        guard !ignoresTwoFingerGesture else { return }

        let point = gesture.translation(in: self)
        // Incremental, and the recogniser's accumulator is reset each time so the next
        // callback reports only what moved since. Re-sending the cumulative translation would
        // make the scroll accelerate away under the user's fingers.
        gesture.setTranslation(.zero, in: self)

        guard point != .zero else { return }
        // A translation is a displacement, not a position: both axes are signed and neither
        // has an origin, which is what `CGSize` means here and `CGPoint` would misdescribe.
        let translation = CGSize(width: point.x, height: point.y)
        if interactionMode.twoFingerDragPansCanvas {
            handlers?.onPanCanvas(translation)
        } else {
            handlers?.onScroll(translation)
        }
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        // Same rule as the one-finger tap: a right click is still a click.
        guard interactionMode.tapsReachTheMac else { return }
        let point = gesture.location(in: self)
        guard !CanvasGeometry.isBlocked(point, regions: blockedRegions) else { return }
        handlers?.onSecondaryClick(point)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard interactionMode.pinchZoomsCanvas else { return }
        let point = gesture.location(in: self)
        guard !CanvasGeometry.isBlocked(point, regions: blockedRegions) else { return }
        let scale = gesture.scale
        gesture.scale = 1
        guard scale != 1 else { return }
        handlers?.onZoom(scale, point)
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

    /// Whether a touch belongs to the window's own chrome rather than to the Mac.
    ///
    /// The gesture surface is a UIKit view and the chrome is drawn over it by SwiftUI, which is
    /// not enough to keep a touch on a button from reaching the Mac as well. A pan recogniser
    /// begins after ten points of travel, and a thumb pressing a button near the edge of the
    /// screen slides further than that without meaning to — so the drag starts on the surface
    /// underneath and the Mac's pointer jumps to wherever the finger happened to be, while the
    /// button it was aimed at also fires. There is nothing in the geometry to tell the two apart;
    /// the caller knows where its chrome is, so it says so.
    static func isBlocked(_ point: CGPoint, regions: [CGRect]) -> Bool {
        regions.contains { $0.contains(point) }
    }

    /// Whether a tap should put an open panel away rather than reach the Mac.
    ///
    /// A pure decision for the same reason ``InteractionMode``'s routing is: a
    /// `UITapGestureRecognizer` cannot be driven from a unit test, and the whole of the behaviour
    /// is this one question. The chrome check is what keeps a tap *on* the panel from counting —
    /// a tap inside one belongs to the button under it, and dismissing on that would close the
    /// panel out from under the tile the user was aiming at.
    static func dismissesPanel(at point: CGPoint, regions: [CGRect], isPanelOpen: Bool) -> Bool {
        isPanelOpen && !isBlocked(point, regions: regions)
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
