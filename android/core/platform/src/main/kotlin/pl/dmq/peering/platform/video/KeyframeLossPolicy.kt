package pl.dmq.peering.platform.video

/**
 * When the decoder must drop what it holds. A frame it could not take, or a codec error, leaves the frames after it
 * referring to pictures the decoder never saw, so it flushes and takes nothing until a keyframe. A new configuration
 * builds a new decoder, which starts at a keyframe without a flush of the old one.
 */
class KeyframeLossPolicy {
    private var awaitingKeyframe = true

    /** True when a frame may reach the decoder. Frames before the next keyframe are skipped, not flushed. */
    fun admit(isKeyframe: Boolean): Boolean {
        if (awaitingKeyframe && !isKeyframe) return false
        awaitingKeyframe = false
        return true
    }

    /** The codec reported an error. True: the decoder must flush before its next input. */
    fun onDecodeError(): Boolean = lose()

    /** A frame could not be queued, so the decoder never received it. True: the decoder must flush. */
    fun onInputDropped(): Boolean = lose()

    fun onConfigChanged() {
        awaitingKeyframe = true
    }

    private fun lose(): Boolean {
        awaitingKeyframe = true
        return true
    }
}
