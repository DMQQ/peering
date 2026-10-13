package pl.dmq.peering.session.audio

import pl.dmq.peering.wire.EncodedAudioFrame
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Turns the computer's interleaved little endian Float32 bytes into the samples the output plays. */
object PcmFrames {
    /**
     * The samples of [frame] for [format], interleaved over [AudioStreamFormat.outputChannels]. Null when the frame does
     * not belong to the stream: a different channel count means a config was missed. Samples that are not numbers play
     * as silence, and none is louder than full scale.
     */
    fun toOutput(frame: EncodedAudioFrame, format: AudioStreamFormat): FloatArray? {
        if (frame.channelCount != format.sourceChannels) return null
        val source = ByteBuffer.wrap(frame.samples).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        val out = format.outputChannels
        val result = FloatArray(frame.sampleCount * out)
        for (index in 0 until frame.sampleCount) {
            for (channel in 0 until out) {
                result[index * out + channel] = tame(source.get(index * frame.channelCount + channel))
            }
        }
        return result
    }

    private fun tame(sample: Float): Float = if (sample.isNaN()) 0f else sample.coerceIn(-1f, 1f)
}
