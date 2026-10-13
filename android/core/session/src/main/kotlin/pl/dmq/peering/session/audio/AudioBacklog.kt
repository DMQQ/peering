package pl.dmq.peering.session.audio

import java.util.ArrayDeque

/**
 * The sound waiting to be played. Playing starts only once [prebufferMillis] has gathered, so a late packet does not
 * stutter it, and starts again after the queue runs dry. A queue that grows past [maxMillis] (the host sent faster than
 * the output drains, or the output stalled) drops its oldest sound down to the prebuffer, so the delay never builds.
 * Safe to call from the thread that receives and the thread that plays.
 */
class AudioBacklog(private val format: AudioStreamFormat, prebufferMillis: Int = 60, maxMillis: Int = 250) {
    private val prebufferFrames = framesFor(prebufferMillis)
    private val maxFrames = framesFor(maxMillis)
    private val chunks = ArrayDeque<FloatArray>()
    private var queuedFrames = 0
    private var primed = false

    /** Sound frames dropped to catch up, and times the queue ran dry while playing. */
    var droppedFrames = 0L
        private set
    var underruns = 0
        private set

    @Synchronized
    fun offer(samples: FloatArray) {
        if (samples.isEmpty()) return
        chunks.addLast(samples)
        queuedFrames += samples.size / format.outputChannels
        if (queuedFrames >= prebufferFrames) primed = true
        if (queuedFrames > maxFrames) trimToPrebuffer()
    }

    /** The next sound to play, or null while the prebuffer fills or nothing is queued. */
    @Synchronized
    fun poll(): FloatArray? {
        if (!primed) return null
        val next = chunks.pollFirst()
        if (next == null) {
            primed = false
            underruns += 1
            return null
        }
        queuedFrames -= next.size / format.outputChannels
        return next
    }

    @Synchronized
    fun clear() {
        chunks.clear()
        queuedFrames = 0
        primed = false
    }

    private fun trimToPrebuffer() {
        while (queuedFrames > prebufferFrames && chunks.size > 1) {
            val dropped = chunks.removeFirst().size / format.outputChannels
            queuedFrames -= dropped
            droppedFrames += dropped
        }
    }

    private fun framesFor(millis: Int): Int = format.sampleRate * millis / MILLIS_PER_SECOND

    private companion object {
        const val MILLIS_PER_SECOND = 1000
    }
}
