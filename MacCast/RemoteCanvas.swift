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
    /// The picture can be inspected, while every input command is blocked.
    case observe

    var id: String { rawValue }

    var label: String {
        switch self {
        case .control: return "View & scroll"
        case .navigate: return "Drag & zoom"
        case .observe: return "Observe"
        }
    }

    var symbol: String {
        switch self {
        case .control: return "hand.point.up.left"
        case .navigate: return "arrow.up.left.and.arrow.down.right"
        case .observe: return "eye"
        }
    }

    var toggled: InteractionMode {
        switch self {
        case .control: return .navigate
        case .navigate: return .observe
        case .observe: return .control
        }
    }
}

extension InteractionMode {
    /// Whether a one-finger drag moves the picture rather than the Mac's pointer.
    var oneFingerDragPansCanvas: Bool { self != .control }

    /// Whether a two-finger drag moves the picture rather than scrolling the Mac.
    ///
    /// Always in drag & zoom. In view & scroll only while the picture is larger than the view
    /// it is drawn in, which is the one case where there is somewhere to pan *to*. Fitted, with
    /// bars down either side, the gesture keeps its other meaning and scrolls the Mac.
    ///
    /// **The rule is about the picture, not about history.** An earlier version keyed off the
    /// zoom alone, and was argued against on the grounds that the same gesture would do
    /// different things depending on what the user had done minutes earlier. That objection
    /// holds when the cause is invisible; it does not hold here, because a picture that
    /// overflows its view is the thing the user is looking at. The zoom is on screen in the
    /// pill besides — see the percentage readout in ``RemoteScreen``.
    func twoFingerDragPansCanvas(isZoomed: Bool) -> Bool {
        self != .control || isZoomed
    }

    /// Whether a tap is a click on the Mac. False in drag & zoom, where a tap is nothing at all
    /// — the mode exists so the picture can be moved and inspected without anything landing on
    /// the Mac by accident.
    var tapsReachTheMac: Bool { self == .control }

    /// Whether a pinch resizes the picture. Drag & zoom only.
    ///
    /// This was both modes, on the argument that looking closer is not a mode — that a user who
    /// wants to read a menu bar should not have to hand the pointer over to do it. The argument
    /// holds in principle and lost to the gesture beside it: in view & scroll the two fingers of
    /// a pinch *are* two fingers on the Mac, and a picture that grows under them is the one
    /// thing in that mode not supposed to move without being asked.
    ///
    /// Gating it costs nothing structurally, which is why the gate was left here to close. The
    /// guard below runs before `isPinching` is set, so a pinch in view & scroll never claims its
    /// fingers — and what it falls through to is the two-finger scroll, which is what those
    /// fingers were going to do anyway.
    var pinchZoomsCanvas: Bool { self != .control }
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
    /// Whether the picture is drawn larger than the view it is in — `RemoteScreen`'s
    /// `effectiveZoom > 1`. Read by the two-finger handler to decide whether a drag has
    /// anywhere to pan to, or should keep scrolling the Mac.
    var isZoomed: Bool = false
    /// The window's own chrome, in the canvas's coordinates. See ``CanvasGeometry/isBlocked``.
    var blockedRegions: [CGRect] = []
    /// Whether a floating panel is open. A tap on the picture then closes it instead of clicking
    /// the Mac — see ``GestureSurfaceView/handleTap(_:)``.
    var isPanelOpen: Bool = false
    /// Called when such a tap lands.
    var onDismissPanel: () -> Void = {}
    /// Whether the status bar is expanded. Same rule as a panel: a tap on the picture closes it
    /// rather than reaching the Mac. One tap does one thing.
    var isStatusBarExpanded: Bool = false
    var onCollapseStatusBar: () -> Void = {}
    /// Whether the software keyboard is up, and what to do when a tap lands on the picture.
    ///
    /// The same rule as a panel, for the same reason: the keyboard is a second thing of ours open
    /// over the picture, and a tap that misses it belongs to closing it.
    var isKeyboardOpen: Bool = false
    var onDismissKeyboard: () -> Void = {}

    func makeUIView(context: Context) -> GestureSurfaceView {
        let view = GestureSurfaceView()
        view.interactionMode = interactionMode
        view.isZoomed = isZoomed
        view.blockedRegions = blockedRegions
        view.isPanelOpen = isPanelOpen
        view.onDismissPanel = onDismissPanel
        view.isStatusBarExpanded = isStatusBarExpanded
        view.onCollapseStatusBar = onCollapseStatusBar
        view.isKeyboardOpen = isKeyboardOpen
        view.onDismissKeyboard = onDismissKeyboard
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
        view.isZoomed = isZoomed
        view.blockedRegions = blockedRegions
        view.isPanelOpen = isPanelOpen
        view.onDismissPanel = onDismissPanel
        view.isStatusBarExpanded = isStatusBarExpanded
        view.onCollapseStatusBar = onCollapseStatusBar
        view.isKeyboardOpen = isKeyboardOpen
        view.onDismissKeyboard = onDismissKeyboard
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
    var interactionMode: InteractionMode = .control

    /// Whether the picture is drawn larger than this view. Decides whether a two-finger drag
    /// has anywhere to pan to, or should go on scrolling the Mac.
    var isZoomed = false

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
    /// The status bar, by the same rule — see ``CanvasGestureView/isStatusBarExpanded``.
    var isStatusBarExpanded = false
    var onCollapseStatusBar: (() -> Void)?
    /// The same, for the software keyboard.
    var isKeyboardOpen = false
    var onDismissKeyboard: (() -> Void)?

    /// Set when a gesture began over the chrome, and cleared when it ends.
    ///
    /// Latched for the life of the gesture rather than re-tested each sample: a finger that
    /// starts on a button and slides off it is still pressing that button, and handing the drag
    /// to the Mac the moment it crossed the chrome's edge would be the same bug in a new place.
    private var ignoresCurrentGesture = false

    /// The same latch for the two-finger family, which has its own began/ended cycle.
    private var ignoresTwoFingerGesture = false

    /// Whether the two-finger drag in progress is moving the picture rather than the Mac.
    ///
    /// Latched at `.began` for the same reason as the chrome latch above, and a stronger one:
    /// re-deciding per sample would let a drag that crosses the zoom threshold mid-gesture
    /// change its meaning under the user's fingers, jumping the picture or the Mac's content
    /// by however far the drag had got.
    private var twoFingerDragPansCanvas = false

    /// Whether a pinch is currently in progress.
    ///
    /// A pinch reports a translation as well as a scale — the fingers move apart *and* drift —
    /// so without this the same two fingers would zoom the picture and scroll the Mac at once,
    /// and the page would slide away under a user who was only trying to look closer at a
    /// corner of it.
    private var isPinching = false

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
            // accelerate away from the finger.
            let moved = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
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
        if CanvasGeometry.dismissesOverlay(at: point, regions: blockedRegions, isOpen: isPanelOpen) {
            onDismissPanel?()
            return
        }
        // After the panel, so a tap that closes a panel does not also put the keyboard away: one
        // tap, one thing closed, and the panel is the one on top.
        if CanvasGeometry.dismissesOverlay(at: point, regions: blockedRegions, isOpen: isKeyboardOpen) {
            onDismissKeyboard?()
            return
        }
        // The status bar, after the panels so that one tap closes one thing: if a panel is
        // open it is the thing on top, and it is the one the tap was aimed at.
        if CanvasGeometry.dismissesOverlay(at: point, regions: blockedRegions, isOpen: isStatusBarExpanded) {
            onCollapseStatusBar?()
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
            // Decided once, here, rather than per sample — see `twoFingerDragPansCanvas`.
            twoFingerDragPansCanvas = interactionMode.twoFingerDragPansCanvas(isZoomed: isZoomed)
        }
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            ignoresTwoFingerGesture = false
        }
        guard !ignoresTwoFingerGesture else { return }

        // The pinch owns both fingers while it lasts. Its translation is the user repositioning
        // the picture under the pinch, not a scroll wheel.
        guard !isPinching else { return }

        let point = gesture.translation(in: self)
        // Incremental, and the recogniser's accumulator is reset each time so the next
        // callback reports only what moved since. Re-sending the cumulative translation would
        // make the scroll accelerate away under the user's fingers.
        gesture.setTranslation(.zero, in: self)

        guard point != .zero else { return }
        // A translation is a displacement, not a position: both axes are signed and neither
        // has an origin, which is what `CGSize` means here and `CGPoint` would misdescribe.
        let translation = CGSize(width: point.x, height: point.y)
        if twoFingerDragPansCanvas {
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

        // Set before the chrome check below, so a pinch that begins over a panel still owns its
        // two fingers and does not scroll the Mac behind the panel.
        switch gesture.state {
        case .began, .changed: isPinching = true
        case .ended, .cancelled, .failed: isPinching = false
        default: break
        }

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

    /// Whether a tap should put something of ours away rather than reach the Mac.
    ///
    /// A panel and the software keyboard are the same thing from the picture's point of view:
    /// something of ours is open over it, and a tap on the picture belongs to closing that rather
    /// than to the Mac underneath. One decision asked twice with different answers for "is it
    /// open", rather than two functions that would drift apart at the first change.
    ///
    /// A pure decision for the same reason ``InteractionMode``'s routing is: a
    /// `UITapGestureRecognizer` cannot be driven from a unit test, and the whole of the behaviour
    /// is this one question. The chrome check is what keeps a tap *on* the panel from counting —
    /// a tap inside one belongs to the button under it, and dismissing on that would close the
    /// panel out from under the tile the user was aiming at.
    static func dismissesOverlay(at point: CGPoint, regions: [CGRect], isOpen: Bool) -> Bool {
        isOpen && !isBlocked(point, regions: regions)
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
