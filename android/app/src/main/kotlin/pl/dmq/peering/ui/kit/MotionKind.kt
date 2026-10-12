package pl.dmq.peering.ui.kit

/** The movement a change of screen gets; each kind is built in [motionTransition]. */
enum class MotionKind { FADE_THROUGH, FORWARD, BACKWARD, CROSSFADE, FADE, MODAL_UP, MODAL_DOWN, PUSH_IN, PUSH_OUT }

/** Going deeper in a flow slides forward, coming back slides back, and a swap between peers only crossfades. */
fun depthMotion(fromDepth: Int, toDepth: Int): MotionKind = when {
    toDepth > fromDepth -> MotionKind.FORWARD
    toDepth < fromDepth -> MotionKind.BACKWARD
    else -> MotionKind.CROSSFADE
}

/** A screen that shows live video never slides: either side of it only fades. */
fun stageMotion(fromDepth: Int, fromLive: Boolean, toDepth: Int, toLive: Boolean): MotionKind =
    if (fromLive || toLive) MotionKind.FADE else depthMotion(fromDepth, toDepth)

/** A full-height panel rises from the bottom edge and sinks back; one panel replacing another only crossfades. */
fun modalMotion(fromModal: Boolean, toModal: Boolean): MotionKind = when {
    toModal && !fromModal -> MotionKind.MODAL_UP
    fromModal && !toModal -> MotionKind.MODAL_DOWN
    else -> MotionKind.CROSSFADE
}

/** A full-screen page over live video slides in from the right edge and back out to it; the picture underneath stays put. */
fun pushMotion(fromPage: Boolean, toPage: Boolean): MotionKind = when {
    toPage && !fromPage -> MotionKind.PUSH_IN
    fromPage && !toPage -> MotionKind.PUSH_OUT
    else -> MotionKind.CROSSFADE
}
