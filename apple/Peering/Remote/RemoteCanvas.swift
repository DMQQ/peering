import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

struct CanvasGestureView: UIViewRepresentable {
    var onTouchDown: (CGPoint) -> Void
    var onTouchMove: (CGPoint) -> Void
    var onTouchUp: (CGPoint) -> Void
    var onSecondaryClick: (CGPoint) -> Void
    var onHover: (CGPoint) -> Void = { _ in }
    var onScroll: (CGSize) -> Void
    var onZoom: (CGFloat, CGPoint) -> Void
    var onPanCanvas: (CGSize) -> Void
    var onSizeChange: (CGSize) -> Void
    var interactionMode: InteractionMode
    var isZoomed: Bool = false
    var blockedRegions: [CGRect] = []
    var isMosaicShowing: Bool = false
    var onMosaicTap: (CGPoint) -> Void = { _ in }
    var onMosaicLift: (CGPoint) -> Void = { _ in }
    var onMosaicDrag: (CGPoint) -> Void = { _ in }
    var onMosaicDrop: () -> Void = {}
    var onPictureTap: () -> Bool = { false }
    func makeUIView(context: Context) -> GestureSurfaceView {
        let view = GestureSurfaceView()
        view.interactionMode = interactionMode
        view.isZoomed = isZoomed
        view.blockedRegions = blockedRegions
        view.isMosaicShowing = isMosaicShowing
        view.handlers = .init(
            onTouchDown: onTouchDown,
            onTouchMove: onTouchMove,
            onTouchUp: onTouchUp,
            onSecondaryClick: onSecondaryClick,
            onHover: onHover,
            onScroll: onScroll,
            onZoom: onZoom,
            onPanCanvas: onPanCanvas,
            onSizeChange: onSizeChange,
            onMosaicTap: onMosaicTap,
            onMosaicLift: onMosaicLift,
            onMosaicDrag: onMosaicDrag,
            onMosaicDrop: onMosaicDrop,
            onPictureTap: onPictureTap
        )
        return view
    }

    func updateUIView(_ view: GestureSurfaceView, context: Context) {
        // The closures capture the current view state (zoom, pan, canvas size), so they are
        // replaced on every update rather than captured once in `makeUIView`.
        view.interactionMode = interactionMode
        view.isZoomed = isZoomed
        view.blockedRegions = blockedRegions
        view.isMosaicShowing = isMosaicShowing
        view.handlers = .init(
            onTouchDown: onTouchDown,
            onTouchMove: onTouchMove,
            onTouchUp: onTouchUp,
            onSecondaryClick: onSecondaryClick,
            onHover: onHover,
            onScroll: onScroll,
            onZoom: onZoom,
            onPanCanvas: onPanCanvas,
            onSizeChange: onSizeChange,
            onMosaicTap: onMosaicTap,
            onMosaicLift: onMosaicLift,
            onMosaicDrag: onMosaicDrag,
            onMosaicDrop: onMosaicDrop,
            onPictureTap: onPictureTap
        )
    }
}

final class GestureSurfaceView: UIView, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
    struct Handlers {
        var onTouchDown: (CGPoint) -> Void
        var onTouchMove: (CGPoint) -> Void
        var onTouchUp: (CGPoint) -> Void
        var onSecondaryClick: (CGPoint) -> Void
        var onHover: (CGPoint) -> Void
        var onScroll: (CGSize) -> Void
        var onZoom: (CGFloat, CGPoint) -> Void
        var onPanCanvas: (CGSize) -> Void
        var onSizeChange: (CGSize) -> Void
        var onMosaicTap: (CGPoint) -> Void
        var onMosaicLift: (CGPoint) -> Void
        var onMosaicDrag: (CGPoint) -> Void
        var onMosaicDrop: () -> Void
        var onPictureTap: () -> Bool
    }

    var handlers: Handlers?

    var interactionMode: InteractionMode = .control

    var isZoomed = false

    var isMosaicShowing = false

    var blockedRegions: [CGRect] = []

    /// Latched for the life of the gesture rather than re-tested each sample: a finger that
    /// starts on a button and slides off it is still pressing that button, and handing the drag
    /// to the Mac the moment it crossed the chrome's edge would be the same bug in a new place.
    private var ignoresCurrentGesture = false

    private var ignoresTwoFingerGesture = false

    /// Latched at `.began` for the same reason as the chrome latch above, and a stronger one:
    /// re-deciding per sample would let a drag that crosses the zoom threshold mid-gesture
    /// change its meaning under the user's fingers, jumping the picture or the Mac's content
    /// by however far the drag had got.
    private var twoFingerDragPansCanvas = false

    /// A pinch reports a translation as well as a scale — the fingers move apart *and* drift —
    /// so without this the same two fingers would zoom the picture and scroll the Mac at once,
    /// and the page would slide away under a user who was only trying to look closer at a
    /// corner of it.
    private var isPinching = false

    /// The same latch as ``ignoresCurrentGesture``, reached from the pinch's side. A pinch reports
    /// the point it is *centred on* rather than either finger, so two fingers that walk up the
    /// screen as they close carry that point over the dock without either finger being anywhere
    /// near it — and re-testing the point on every sample stopped the zoom halfway through the
    /// gesture, with `isPinching` left set and both drag handlers still standing down.
    private var pinchIgnoresChrome = false

    private var suppressTwoFingerPanUntilEnd = false

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

    /// `allowableMovement` is what makes it work at all beside the drag. A press that has not moved
    /// more than this is still a press, so a finger that goes down and stays still for the duration
    /// lifts a tile; a finger that moves is a drag, and the press fails before anything has been
    /// lifted. That is also why the drag is made to wait for this one to fail rather than the other
    /// way round — see the `require(toFail:)` below.
    private lazy var mosaicLift: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleMosaicLift))
        gesture.minimumPressDuration = 0.4
        gesture.allowableMovement = 12
        gesture.numberOfTouchesRequired = 1
        return gesture
    }()

    // MARK: Trackpad and mouse

    private lazy var hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover))

    private lazy var pointerScroll: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handlePointerScroll))
        gesture.allowedScrollTypesMask = .all
        gesture.allowedTouchTypes = []
        return gesture
    }()

    private lazy var pointerSecondaryClick: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
        gesture.buttonMaskRequired = .secondary
        gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        return gesture
    }()

    private var pointerScrollPansCanvas = false

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
        addGestureRecognizer(mosaicLift)
        addGestureRecognizer(hover)
        addGestureRecognizer(pointerScroll)
        addGestureRecognizer(pointerSecondaryClick)
        addInteraction(UIPointerInteraction(delegate: self))

        oneFingerTap.require(toFail: oneFingerPan)
        twoFingerTap.require(toFail: twoFingerPan)
        twoFingerTap.require(toFail: pinch)
        // **The one-finger pair waits for the lift to fail, and the lift fails immediately** —
        // on the first movement past `allowableMovement`, or the moment the finger comes up short
        // of the press. So a drag and a tap wait for nothing they can feel, and the two gestures
        // that must not happen at the same time as a lift cannot. The other order — the lift
        // waiting for the drag to fail — would delay every lift by however long the drag takes to
        // decide it is not a drag, which is most of the press.
        oneFingerPan.require(toFail: mosaicLift)
        oneFingerTap.require(toFail: mosaicLift)

        // Pinch and two-finger pan must fire at the same time so the user can zoom-and-reposition
        // in one gesture. Without this, iOS picks whichever started first and cancels the other,
        // which makes the view jump as soon as the user shifts the pinch centroid.
        pinch.delegate = self
        twoFingerPan.delegate = self
        oneFingerPan.delegate = self
        oneFingerTap.delegate = self
    }

    /// This is what stops the canvas eating taps aimed at the chrome. This view covers the whole
    /// screen and sits under every control the app draws, and a recogniser that begins on the way
    /// to a button takes the touch with it — `cancelsTouchesInView` is on by default — so the
    /// button never sees the press. The result is a control that works on the second or third
    /// attempt, depending on whether the recogniser happened to be mid-something on the first.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let point = gestureRecognizer.location(in: self)
        let blocked = CanvasGeometry.isBlocked(point, regions: blockedRegions)
        // The lift only exists in an arrangement, and says so here rather than inside its handler:
        // a recogniser that begins and then decides to do nothing has already held up the tap and
        // the drag behind it. A refusal here is a failure, which is what the two `require(toFail:)`
        // above are waiting for.
        if gestureRecognizer === mosaicLift, !isMosaicShowing { return false }
        return !blocked
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // It was the two-finger drag alone, and the omission cost the pinch. Two fingers that
        // land together are fine: the one-finger drag fails on the second touch and the pinch
        // takes over. Two fingers that land *apart* are not — the first one begins a drag before
        // the second arrives, and with the pair exclusive the pinch was never allowed to start
        // while that drag was still running. So the pointer went on following the first finger
        // under a hand that thought it was zooming, which is exactly what it looked like.
        let drags: Set<UIGestureRecognizer> = [oneFingerPan, twoFingerPan]
        let involvesPinch = gestureRecognizer === pinch || other === pinch
        let allowed = involvesPinch && !(drags.contains(gestureRecognizer) && drags.contains(other))
        return allowed
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The window's size, not this view's: the keyboard animates this view's height even though
        // it ignores the safe area, and the picture is fitted to what is reported here.
        let size = window?.bounds.size ?? bounds.size
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

        // The end of the gesture is not skipped along with its movement. A drag that began
        // before the pinch did has already put the Mac's button down, and a release that never
        // follows is a button held down on someone else's Mac until they notice.
        if isPinching {
            // The movement is dropped rather than saved up. A translation accumulated during the
            // pinch would land in one jump the moment the pinch ended and this drag resumed.
            gesture.setTranslation(.zero, in: self)
            guard isEnding, !interactionMode.oneFingerDragPansCanvas else { return }
            handlers?.onTouchUp(point)
            return
        }

        if interactionMode.oneFingerDragPansCanvas {
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

    /// `.failed` is deliberately not a drop. A press that failed is one that never lifted anything
    /// — the finger moved, or came up too soon — and telling the screen that a tile was let go when
    /// none was picked up would be a message about a gesture that did not happen.
    @objc private func handleMosaicLift(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            handlers?.onMosaicLift(point)
        case .changed:
            handlers?.onMosaicDrag(point)
        case .ended, .cancelled:
            handlers?.onMosaicDrop()
        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        // **A tap on the picture closes an open panel, and goes no further.** The panel covers part
        // of the picture, so a tap beside it is a tap on something only half visible; it is read
        // as "put this away". The keyboard is the exception and stays open: tapping a text field
        // on the Mac is how typing starts, and a first tap that only put the keyboard away was the
        // reason this used to be off for everything. The expanded pill closes too, but that tap
        // still reaches the Mac.
        guard !CanvasGeometry.isBlocked(point, regions: blockedRegions) else { return }

        if handlers?.onPictureTap() == true { return }

        // **A mosaic comes before the mode guard, and that is not an oversight.** Selecting a
        // tile sends no input: it asks the Mac for that one source, which is the same kind of
        // command as opening a panel or choosing from the sources list, and both of those work
        // in observe mode. What observe mode refuses is *touching* the Mac, and this is the app
        // deciding what to show rather than a finger landing on a window.
        if isMosaicShowing {
            handlers?.onMosaicTap(point)
            return
        }

        guard interactionMode.tapsReachTheMac else { return }
        handlers?.onTouchDown(point)
        handlers?.onTouchUp(point)
    }

    // MARK: - Two fingers

    @objc private func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began {
            let start = gesture.location(in: self)
            ignoresTwoFingerGesture = CanvasGeometry.isBlocked(start, regions: blockedRegions)
            suppressTwoFingerPanUntilEnd = false
            twoFingerDragPansCanvas = interactionMode.twoFingerDragPansCanvas(isZoomed: isZoomed)
        }
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            ignoresTwoFingerGesture = false
        }
        guard !ignoresTwoFingerGesture else { return }

        let isEnding = gesture.state == .ended
            || gesture.state == .cancelled
            || gesture.state == .failed

        // During a pinch the simultaneous pan recognizer is the single owner of shared finger
        // movement. The pinch recognizer below applies scale only; letting both callbacks pan
        // would apply the same centroid delta twice (the visible rightward snap).
        if !suppressTwoFingerPanUntilEnd,
           isPinching || pinch.state == .began || pinch.state == .changed {
            let movement = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            if let movement = CanvasGestureRouting.pinchPanTranslation(
                translation: movement,
                suppressingAfterPinch: false
            ) {
                handlers?.onPanCanvas(CGSize(width: movement.x, height: movement.y))
            }
            return
        }

        if !CanvasGestureRouting.shouldDeliverTwoFingerPan(
            whilePinching: isPinching,
            suppressingAfterPinch: suppressTwoFingerPanUntilEnd
        ) {
            gesture.setTranslation(.zero, in: self)
            if isEnding { suppressTwoFingerPanUntilEnd = false }
            return
        }

        let decision = CanvasGestureRouting.twoFingerPan(
            translation: gesture.translation(in: self),
            whilePinching: isPinching
        )
        if decision.resetsRecognizerTranslation {
            gesture.setTranslation(.zero, in: self)
        }
        guard let point = decision.translation else { return }
        let translation = CGSize(width: point.x, height: point.y)
        if twoFingerDragPansCanvas {
            handlers?.onPanCanvas(translation)
        } else {
            handlers?.onScroll(translation)
        }
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        guard interactionMode.tapsReachTheMac else { return }
        let point = gesture.location(in: self)
        guard !CanvasGeometry.isBlocked(point, regions: blockedRegions) else { return }
        handlers?.onSecondaryClick(point)
    }

    // MARK: - Trackpad and mouse

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed else { return }
        guard interactionMode.tapsReachTheMac, !isMosaicShowing else { return }
        let point = gesture.location(in: self)
        guard !CanvasGeometry.isBlocked(point, regions: blockedRegions) else { return }
        handlers?.onHover(point)
    }

    @objc private func handlePointerScroll(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began {
            pointerScrollPansCanvas = interactionMode.twoFingerDragPansCanvas(isZoomed: isZoomed)
        }
        let moved = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        guard moved != .zero else { return }
        let translation = CGSize(width: moved.x, height: moved.y)
        if pointerScrollPansCanvas {
            handlers?.onPanCanvas(translation)
        } else if interactionMode.tapsReachTheMac, !isMosaicShowing {
            handlers?.onScroll(translation)
        }
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        regionFor request: UIPointerRegionRequest,
        defaultRegion: UIPointerRegion
    ) -> UIPointerRegion? {
        guard interactionMode.tapsReachTheMac, !isMosaicShowing,
              !CanvasGeometry.isBlocked(request.location, regions: blockedRegions)
        else { return nil }
        return defaultRegion
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        .hidden()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        // **A pinch resizes the picture, in every mode.**

        // Set before the chrome check below, so a pinch that begins over a panel still owns its
        // two fingers and does not scroll the Mac behind the panel.
        switch gesture.state {
        case .began:
            pinchIgnoresChrome = CanvasGeometry.isBlocked(
                gesture.location(in: self),
                regions: blockedRegions
            )
            isPinching = true
        case .changed:
            isPinching = true
        case .ended, .cancelled, .failed:
            isPinching = false
            suppressTwoFingerPanUntilEnd = true
        default:
            break
        }
        guard !pinchIgnoresChrome else { return }

        let point = gesture.location(in: self)

        let phase: CanvasGestureRouting.PinchPhase = switch gesture.state {
        case .began: .began
        case .changed: .changed
        case .ended: .ended
        case .cancelled: .cancelled
        case .failed: .failed
        default: .changed
        }
        let scale = gesture.scale
        gesture.scale = 1
        guard let appliedScale = CanvasGestureRouting.pinchScale(for: phase, scale: scale) else { return }
        handlers?.onZoom(appliedScale, point)
    }
}
