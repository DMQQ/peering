package pl.dmq.peering.platform.video

import pl.dmq.peering.wire.VideoStreamConfig

/**
 * Decides whether a decoder that failed is built again. A host that resends the same config after every failure would
 * otherwise make the phone rebuild the same broken codec for ever, so rebuilding stops after [maxRebuilds] failures
 * with no picture decoded in between, and the stream stays failed until a different config arrives.
 */
class DecoderRecovery(private val maxRebuilds: Int = DEFAULT_MAX_REBUILDS) {
    private var failures = 0
    private var abandoned: VideoStreamConfig? = null

    /** True once the decoder gave up on a stream. */
    val failed: Boolean get() = abandoned != null

    /** The codec failed for good. True: build it again. False: stop trying for [config]. */
    fun onFatal(config: VideoStreamConfig): Boolean {
        failures += 1
        if (failures <= maxRebuilds) return true
        abandoned = config
        return false
    }

    /** A picture came out of the decoder, so the failures so far were not a loop. */
    fun onPictureDecoded() {
        failures = 0
    }

    /** True when [config] is the one given up on, and so must not be started again. */
    fun refuses(config: VideoStreamConfig): Boolean = config == abandoned

    /** A config the decoder can try afresh. */
    fun onNewConfig() {
        failures = 0
        abandoned = null
    }

    companion object {
        const val DEFAULT_MAX_REBUILDS = 3
    }
}
