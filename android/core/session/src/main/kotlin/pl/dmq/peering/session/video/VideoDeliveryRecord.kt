package pl.dmq.peering.session.video

import kotlin.math.roundToInt
import pl.dmq.peering.wire.VideoTransportKind

/** Which transport the picture is on, and how long the first picture took after the session became ready. */
class VideoDeliveryRecord(private val readyAt: Double) {
    var transport: VideoTransportKind = VideoTransportKind.PRIMARY
        private set

    /** Sticky: a session that returned to the primary lane still needed the fallback. */
    var fellBack: Boolean = false
        private set

    private var firstPictureAt: Double? = null

    fun notePicture(now: Double) {
        if (firstPictureAt == null) firstPictureAt = now
    }

    fun note(transport: VideoTransportKind) {
        this.transport = transport
        if (transport == VideoTransportKind.CONTROL) fellBack = true
    }

    /** Null when no picture arrived, or when the first one is dated before the session was ready. */
    val firstPictureMilliseconds: Int?
        get() {
            val first = firstPictureAt ?: return null
            if (first < readyAt) return null
            return ((first - readyAt) * MILLIS_PER_SECOND).roundToInt()
        }

    private companion object {
        const val MILLIS_PER_SECOND = 1000.0
    }
}
