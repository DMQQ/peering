import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

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
        var onMultiFingerSwipe: (TrackpadSwipe) -> Void
    }

    var handlers: Handlers?

    var interactionMode: InteractionMode = .control

    var isZoomed = false

    var isMosaicShowing = false

    var blockedRegions: [CGRect] = []

    /// Latched for the life of the gesture rather than re-tested each sample: a finger that
    /// starts on a button and slides off it is still pressing that button, and handing the drag
    /// to the Mac the moment it crossed the chrome's edge would be the same bug in a new place.
    var ignoresCurrentGesture = false

    var ignoresTwoFingerGesture = false

    /// Latched at `.began` for the same reason as the chrome latch above, and a stronger one:
    /// re-deciding per sample would let a drag that crosses the zoom threshold mid-gesture
    /// change its meaning under the user's fingers, jumping the picture or the Mac's content
    /// by however far the drag had got.
    var twoFingerDragPansCanvas = false

    /// A pinch reports a translation as well as a scale, the fingers move apart *and* drift,
    /// so without this the same two fingers would zoom the picture and scroll the Mac at once,
    /// and the page would slide away under a user who was only trying to look closer at a
    /// corner of it.
    var isPinching = false

    /// The same latch as ``ignoresCurrentGesture``, reached from the pinch's side. A pinch reports
    /// the point it is *centred on* rather than either finger, so two fingers that walk up the
    /// screen as they close carry that point over the dock without either finger being anywhere
    /// near it, and re-testing the point on every sample stopped the zoom halfway through the
    /// gesture, with `isPinching` left set and both drag handlers still standing down.
    var pinchIgnoresChrome = false

    var suppressTwoFingerPanUntilEnd = false

    lazy var oneFingerPan: UIPanGestureRecognizer = {
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

    lazy var twoFingerPan: UIPanGestureRecognizer = {
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

    lazy var pinch: UIPinchGestureRecognizer = {
        UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
    }()

    /// `allowableMovement` is what makes it work at all beside the drag. A press that has not moved
    /// more than this is still a press, so a finger that goes down and stays still for the duration
    /// lifts a tile; a finger that moves is a drag, and the press fails before anything has been
    /// lifted. That is also why the drag is made to wait for this one to fail rather than the other
    /// way round, see the `require(toFail:)` below.
    private lazy var mosaicLift: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleMosaicLift))
        gesture.minimumPressDuration = 0.4
        gesture.allowableMovement = 12
        gesture.numberOfTouchesRequired = 1
        return gesture
    }()

    /// Fails on movement or a lift short of the press, so the drag and tap that wait for it lose nothing.
    lazy var secondaryPress: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleSecondaryPress))
        gesture.minimumPressDuration = 0.5
        gesture.allowableMovement = 10
        gesture.numberOfTouchesRequired = 1
        return gesture
    }()

    private lazy var multiFingerSwipe: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleMultiFingerSwipe))
        gesture.minimumNumberOfTouches = 3
        gesture.maximumNumberOfTouches = 4
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

    var pointerScrollPansCanvas = false

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
        addGestureRecognizer(secondaryPress)
        addGestureRecognizer(multiFingerSwipe)
        addGestureRecognizer(hover)
        addGestureRecognizer(pointerScroll)
        addGestureRecognizer(pointerSecondaryClick)
        addInteraction(UIPointerInteraction(delegate: self))

        oneFingerTap.require(toFail: oneFingerPan)
        twoFingerTap.require(toFail: twoFingerPan)
        twoFingerTap.require(toFail: pinch)
        // **The one-finger pair waits for the lift to fail, and the lift fails immediately**,
        // on the first movement past `allowableMovement`, or the moment the finger comes up short
        // of the press. So a drag and a tap wait for nothing they can feel, and the two gestures
        // that must not happen at the same time as a lift cannot. The other order, the lift
        // waiting for the drag to fail, would delay every lift by however long the drag takes to
        // decide it is not a drag, which is most of the press.
        oneFingerPan.require(toFail: mosaicLift)
        oneFingerTap.require(toFail: mosaicLift)
        oneFingerPan.require(toFail: secondaryPress)
        oneFingerTap.require(toFail: secondaryPress)

        // Pinch and two-finger pan must fire at the same time so the user can zoom-and-reposition
        // in one gesture. Without this, iOS picks whichever started first and cancels the other,
        // which makes the view jump as soon as the user shifts the pinch centroid.
        pinch.delegate = self
        twoFingerPan.delegate = self
        oneFingerPan.delegate = self
        oneFingerTap.delegate = self
        multiFingerSwipe.delegate = self
    }

    /// This is what stops the canvas eating taps aimed at the chrome. This view covers the whole
    /// screen and sits under every control the app draws, and a recogniser that begins on the way
    /// to a button takes the touch with it, `cancelsTouchesInView` is on by default, so the
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
        if gestureRecognizer === secondaryPress || gestureRecognizer === multiFingerSwipe,
           isMosaicShowing || !interactionMode.tapsReachTheMac {
            return false
        }
        return !blocked
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // It was the two-finger drag alone, and the omission cost the pinch. Two fingers that
        // land together are fine: the one-finger drag fails on the second touch and the pinch
        // takes over. Two fingers that land *apart* are not, the first one begins a drag before
        // the second arrives, and with the pair exclusive the pinch was never allowed to start
        // while that drag was still running. So the pointer went on following the first finger
        // under a hand that thought it was zooming, which is exactly what it looked like.
        // The swipe runs beside the others only so it can begin under fingers that landed apart;
        // its `.began` then cancels them.
        if gestureRecognizer === multiFingerSwipe || other === multiFingerSwipe { return true }
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
}
