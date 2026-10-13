package pl.dmq.peering.feature.remote.dictation

import kotlin.math.pow

/** The loudness history a dictation waveform draws, newest last. */
class DictationLevels private constructor(val bars: List<Float>) {
    constructor() : this(List(BAR_COUNT) { 0f })

    /** The history with one more bar for a reading from the recogniser's RMS callback, and the oldest dropped. */
    fun added(rmsDecibels: Float): DictationLevels = DictationLevels(bars.drop(1) + levelForRms(rmsDecibels))

    override fun equals(other: Any?) = other is DictationLevels && other.bars == bars

    override fun hashCode() = bars.hashCode()

    companion object {
        const val BAR_COUNT = 32

        /** Quieter than this is silence, and the room's own noise floor sits well under it. */
        const val FLOOR_DECIBELS = -50f

        private const val CURVE_EXPONENT = 1.6

        /**
         * SpeechRecognizer reports RMS on a scale of roughly -2 (silence) to 10 (loud speech), not in dBFS. This
         * stretches that span over the same -50..0 range the iPhone's meter reads so one curve serves both.
         */
        private const val RMS_SPAN_SCALE = 5f
        private const val RMS_LOUD = 10f

        /** Maps decibels onto 0 to 1 with a curve that lifts quiet speech, since the ear reads loudness roughly logarithmically. */
        fun levelForDecibels(decibels: Float): Float {
            if (!decibels.isFinite() || decibels <= FLOOR_DECIBELS) return 0f
            val linear = (decibels - FLOOR_DECIBELS) / -FLOOR_DECIBELS
            return linear.toDouble().pow(CURVE_EXPONENT).toFloat().coerceIn(0f, 1f)
        }

        fun levelForRms(rmsDecibels: Float): Float = levelForDecibels((rmsDecibels - RMS_LOUD) * RMS_SPAN_SCALE)
    }
}
