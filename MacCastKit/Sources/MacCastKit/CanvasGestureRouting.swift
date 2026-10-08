import CoreGraphics

/// The part of simultaneous pinch/pan arbitration that does not depend on UIKit's recognizer, so
/// the release-order race stays reproducible without synthesizing private UIKit touch events.
public enum CanvasGestureRouting {
    public enum PinchPhase {
        case began
        case changed
        case ended
        case cancelled
        case failed
    }

    public static func pinchScale(for phase: PinchPhase, scale: CGFloat) -> CGFloat? {
        // The recognizer resets its scale after every callback, so a terminal callback can carry
        // the last stale scale: only began/changed may change the canvas.
        guard phase == .began || phase == .changed, scale != 1 else { return nil }
        return scale
    }

    public static func shouldDeliverTwoFingerPan(
        whilePinching: Bool,
        suppressingAfterPinch: Bool
    ) -> Bool {
        !whilePinching && !suppressingAfterPinch
    }

    /// The simultaneous pan owns shared finger movement while pinch owns scale, so one centroid
    /// delta is never applied twice by the two recognizers.
    public static func pinchPanTranslation(
        translation: CGPoint,
        suppressingAfterPinch: Bool
    ) -> CGPoint? {
        guard !suppressingAfterPinch, translation != .zero else { return nil }
        return translation
    }

    public struct TwoFingerPanDecision {
        public var resetsRecognizerTranslation: Bool
        public var translation: CGPoint?
    }

    public static func twoFingerPan(
        translation: CGPoint,
        whilePinching: Bool
    ) -> TwoFingerPanDecision {
        guard !whilePinching else {
            return TwoFingerPanDecision(
                // Throw the simultaneous pan's copy away now: if UIKit ends the pinch recognizer
                // first, it would otherwise replay the whole gesture.
                resetsRecognizerTranslation: true,
                translation: nil
            )
        }

        return TwoFingerPanDecision(
            resetsRecognizerTranslation: true,
            translation: translation == .zero ? nil : translation
        )
    }
}
