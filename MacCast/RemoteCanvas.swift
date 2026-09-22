import MacCastKit
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
    /// A drag that moves the picture instead of the Mac.
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
    /// Whether a mosaic is on screen. A tap then selects the tile it landed in. See
    /// ``GestureSurfaceView/isMosaicShowing``.
    var isMosaicShowing: Bool = false
    /// Called when a tap lands on a mosaic, with the point in this view's coordinates: the
    /// caller is the one that knows where the picture is inside it.
    var onMosaicTap: (CGPoint) -> Void = { _ in }
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
        view.isMosaicShowing = isMosaicShowing
        view.handlers = .init(
            onTouchDown: onTouchDown,
            onTouchMove: onTouchMove,
            onTouchUp: onTouchUp,
            onSecondaryClick: onSecondaryClick,
            onScroll: onScroll,
            onZoom: onZoom,
            onPanCanvas: onPanCanvas,
            onSizeChange: onSizeChange,
            onMosaicTap: onMosaicTap
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
        view.isMosaicShowing = isMosaicShowing
        view.handlers = .init(
            onTouchDown: onTouchDown,
            onTouchMove: onTouchMove,
            onTouchUp: onTouchUp,
            onSecondaryClick: onSecondaryClick,
            onScroll: onScroll,
            onZoom: onZoom,
            onPanCanvas: onPanCanvas,
            onSizeChange: onSizeChange,
            onMosaicTap: onMosaicTap
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
        /// A tap on a mosaic, which selects the tile it landed in rather than clicking the Mac.
        var onMosaicTap: (CGPoint) -> Void
    }

    var handlers: Handlers?

    /// Whether the fingers drive the Mac or the picture. Read by every handler below.
    var interactionMode: InteractionMode = .control

    /// Whether the picture is drawn larger than this view. Decides whether a two-finger drag
    /// has anywhere to pan to, or should go on scrolling the Mac.
    var isZoomed = false

    /// Whether what is on screen is a mosaic. A tap then selects a tile rather than reaching the
    /// Mac, because a point on a canvas has no meaning over there until a window has been chosen
    /// for it here. See ``MosaicGrid/tileIndex(at:in:)``.
    var isMosaicShowing = false

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

    /// Whether the pinch in progress began over the chrome, and so is resizing nothing.
    ///
    /// The same latch as ``ignoresCurrentGesture``, reached from the pinch's side. A pinch reports
    /// the point it is *centred on* rather than either finger, so two fingers that walk up the
    /// screen as they close carry that point over the dock without either finger being anywhere
    /// near it — and re-testing the point on every sample stopped the zoom halfway through the
    /// gesture, with `isPinching` left set and both drag handlers still standing down.
    private var pinchIgnoresChrome = false

    /// Where the pinch was centred on the previous sample, so its movement can be told from its
    /// scale — see ``handlePinch(_:)``.

    /// Set when the pinch ends before the simultaneous pan recognizer. The fingers can still
    /// report a few points of lift-off movement, which must not become a release jump.
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
        // The one-finger pair as well, now that there is something to ask them. The whole point
        // of a delegate here is ``gestureRecognizerShouldBegin`` below.
        oneFingerPan.delegate = self
        oneFingerTap.delegate = self
    }

    /// Whether a gesture may start here at all.
    ///
    /// This is what stops the canvas eating taps aimed at the chrome. This view covers the whole
    /// screen and sits under every control the app draws, and a recogniser that begins on the way
    /// to a button takes the touch with it — `cancelsTouchesInView` is on by default — so the
    /// button never sees the press. The result is a control that works on the second or third
    /// attempt, depending on whether the recogniser happened to be mid-something on the first.
    ///
    /// It was the dock that made it obvious — press it twice and it goes — but the same theft was
    /// happening to every button in the chrome, including the dots beside the status pill, which
    /// is the "sometimes the terminal button does nothing" that never had an explanation.
    ///
    /// Refusing to begin costs nothing: a touch over the chrome was never going to move the Mac's
    /// pointer anyway. `handleOneFingerPan` checks the same regions at `.began` and that check
    /// stays, because it is the one that holds if a gesture starts just outside a panel and drags
    /// across it.
    // `override` because `UIView` already declares this — it is one of the delegate methods a
    // view answers by default, which is why the scope has to be widened rather than a new one
    // added.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let point = gestureRecognizer.location(in: self)
        let blocked = CanvasGeometry.isBlocked(point, regions: blockedRegions)
        return !blocked
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // The pinch is allowed to run beside both drags, and the one-finger drag beside the
        // pinch. That is not two gestures at once — it is the pinch being allowed to *arrive*
        // while a drag is already watching the first finger, which is the only way a hand that
        // puts one finger down before the other can pinch at all.
        //
        // It was the two-finger drag alone, and the omission cost the pinch. Two fingers that
        // land together are fine: the one-finger drag fails on the second touch and the pinch
        // takes over. Two fingers that land *apart* are not — the first one begins a drag before
        // the second arrives, and with the pair exclusive the pinch was never allowed to start
        // while that drag was still running. So the pointer went on following the first finger
        // under a hand that thought it was zooming, which is exactly what it looked like.
        //
        // Both drag handlers stand down the moment ``isPinching`` is set, so only one of these
        // ever acts; see the guards in `handleOneFingerPan` and `handleTwoFingerPan`.
        //
        // The pinch pairs with either drag; the two drags never pair with each other. That second
        // half is not a nicety — two drags at once is a pointer that goes on moving while the
        // picture scrolls, which is the pairing `maximumNumberOfTouches = 1` exists to make
        // impossible.
        let drags: Set<UIGestureRecognizer> = [oneFingerPan, twoFingerPan]
        let involvesPinch = gestureRecognizer === pinch || other === pinch
        let allowed = involvesPinch && !(drags.contains(gestureRecognizer) && drags.contains(other))
        return allowed
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

        // The pinch owns both fingers once it starts, and this drag is the one that has to give
        // way — see `shouldRecognizeSimultaneouslyWith` above.
        //
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
        // A tap inside chrome belongs to the button that is there, whichever mode this is.
        guard !CanvasGeometry.isBlocked(point, regions: blockedRegions) else { return }

        // **A mosaic comes before the mode guard, and that is not an oversight.** Selecting a
        // tile sends no input: it asks the Mac for that one source, which is the same kind of
        // command as opening a panel or choosing from the sources list, and both of those work
        // in observe mode. What observe mode refuses is *touching* the Mac, and this is the app
        // deciding what to show rather than a finger landing on a window.
        if isMosaicShowing {
            handlers?.onMosaicTap(point)
            return
        }

        // Nothing else reaches the Mac in observe mode.
        guard interactionMode.tapsReachTheMac else { return }
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
            suppressTwoFingerPanUntilEnd = false
            // Decided once, here, rather than per sample — see `twoFingerDragPansCanvas`.
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
        // **A pinch resizes the picture, in every mode.**
        //
        // It was closed on the argument that in view & scroll the two fingers of a pinch *are* two
        // fingers on the Mac, and a picture that grows under them is the one thing in that mode not
        // supposed to move without being asked. That is a real cost, and it is the smaller one:
        // what the gate bought was a gesture that does *nothing* — not something else, nothing — in
        // the mode most sessions are in, on the strength of an argument the user never made. Two
        // fingers that pinch are asking to look closer on every device they have ever used, phone,
        // Mac trackpad and tablet alike, and answering with silence is not protecting anyone from
        // an accident; it is the one place the gesture does not work.
        //
        // Scrolling is not lost with it. That is the two-finger *drag*, which still scrolls the Mac
        // in view & scroll whether or not the picture has been zoomed.

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
