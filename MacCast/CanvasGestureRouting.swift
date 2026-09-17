import CoreGraphics

/// The part of simultaneous pinch/pan arbitration that does not depend on UIKit's recognizer.
/// Keeping this decision visible makes the release-order race reproducible without synthesizing
/// private UIKit touch events.
enum CanvasGestureRouting {
    enum PinchPhase {
        case began
        case changed
        case ended
        case cancelled
        case failed
    }

    static func pinchScale(for phase: PinchPhase, scale: CGFloat) -> CGFloat? {
        // The recognizer's scale is reset after every callback, so only a real began/changed
        // sample may change the canvas. Terminal callbacks can carry the last stale scale.
        guard phase == .began || phase == .changed, scale != 1 else { return nil }
        return scale
    }

    static func shouldDeliverTwoFingerPan(
        whilePinching: Bool,
        suppressingAfterPinch: Bool
    ) -> Bool {
        !whilePinching && !suppressingAfterPinch
    }

    /// The simultaneous pan owns shared finger movement while pinch owns scale. This keeps one
    /// centroid delta from being applied twice by the two recognizers.
    static func pinchPanTranslation(
        translation: CGPoint,
        suppressingAfterPinch: Bool
    ) -> CGPoint? {
        guard !suppressingAfterPinch, translation != .zero else { return nil }
        return translation
    }

    struct TwoFingerPanDecision {
        var resetsRecognizerTranslation: Bool
        var translation: CGPoint?
    }

    static func twoFingerPan(
        translation: CGPoint,
        whilePinching: Bool
    ) -> TwoFingerPanDecision {
        // The pinch owns both fingers while it lasts. Its translation is the user repositioning
        // the picture under the pinch, not a scroll wheel.
        guard !whilePinching else {
            return TwoFingerPanDecision(
                // The pinch reports this movement from its own centre. Throw the simultaneous
                // pan recognizer's copy away now so it cannot replay the whole gesture if UIKit
                // ends the pinch recognizer first.
                resetsRecognizerTranslation: true,
                translation: nil
            )
        }

        // Incremental: the caller resets the recognizer whenever this says the accumulated
        // translation has been consumed.
        return TwoFingerPanDecision(
            resetsRecognizerTranslation: true,
            translation: translation == .zero ? nil : translation
        )
    }
}
