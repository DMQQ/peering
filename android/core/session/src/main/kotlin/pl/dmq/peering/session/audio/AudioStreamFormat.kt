package pl.dmq.peering.session.audio

import pl.dmq.peering.wire.AudioCodec
import pl.dmq.peering.wire.AudioStreamConfig
import kotlin.math.roundToInt

/**
 * What the phone can play of a stream the computer announced. A stream with more than two channels is played as its
 * first two, the front pair, because a phone has no more to play them on.
 */
class AudioStreamFormat private constructor(val sampleRate: Int, val sourceChannels: Int) {
    val outputChannels: Int get() = minOf(sourceChannels, MAX_OUTPUT_CHANNELS)

    companion object {
        private const val MIN_RATE = 8_000.0
        private const val MAX_RATE = 384_000.0
        private const val MAX_SOURCE_CHANNELS = 32
        private const val MAX_OUTPUT_CHANNELS = 2

        /** The format [config] describes, or null when it is outside what the wire allows. */
        fun of(config: AudioStreamConfig): AudioStreamFormat? {
            if (config.codec != AudioCodec.PCM_FLOAT32) return null
            if (!config.sampleRate.isFinite() || config.sampleRate !in MIN_RATE..MAX_RATE) return null
            if (config.channelCount !in 1..MAX_SOURCE_CHANNELS) return null
            return AudioStreamFormat(config.sampleRate.roundToInt(), config.channelCount)
        }
    }
}
