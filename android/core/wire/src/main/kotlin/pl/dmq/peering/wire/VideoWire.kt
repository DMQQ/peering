package pl.dmq.peering.wire

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Base64
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
enum class VideoCodec {
    @SerialName("h264") H264,
    @SerialName("hevc") HEVC,
}

/**
 * Sent when the description changes, never per frame. [parameterSets] is base64 SPS then PPS for H.264,
 * VPS, SPS, PPS for HEVC.
 */
@Serializable
data class VideoStreamConfig(
    val sourceID: String,
    val codec: VideoCodec,
    val pixelWidth: Int,
    val pixelHeight: Int,
    val parameterSets: List<String>,
) {
    fun parameterSetBytes(): List<ByteArray> = parameterSets.map { Base64.getDecoder().decode(it) }

    /** False for a size the peer could use to make the phone allocate an absurd decoder surface. */
    val isWithinLimits: Boolean
        get() = pixelWidth in 1..MAX_PICTURE_SIDE && pixelHeight in 1..MAX_PICTURE_SIDE

    companion object {
        /** The longest side, in pixels, a stream may declare. */
        const val MAX_PICTURE_SIDE = 8192

        /**
         * Null when the candidate has no parameter sets (a delta frame's description is empty, not a reset)
         * or equals the description already sent.
         */
        fun updated(previous: VideoStreamConfig?, candidate: VideoStreamConfig): VideoStreamConfig? =
            if (candidate.parameterSets.isEmpty() || candidate == previous) null else candidate
    }
}

data class VideoTimestamp(val value: Long, val timescale: Int) {
    /** A zero timescale arrives off the network, so it reads as zero rather than dividing by it. */
    val seconds: Double
        get() = if (timescale == 0) 0.0 else value.toDouble() / timescale.toDouble()
}

/** [data] is AVCC: each NAL unit prefixed by its 4 byte big endian length. Parameter sets are not in it. */
class EncodedVideoFrame(
    val isKeyframe: Boolean,
    val pixelWidth: Int,
    val pixelHeight: Int,
    val presentationTime: VideoTimestamp,
    val data: ByteArray,
) {
    fun encode(): ByteArray {
        val buffer = ByteBuffer.allocate(HEADER_SIZE + data.size).order(ByteOrder.BIG_ENDIAN)
        buffer.put(if (isKeyframe) KEYFRAME_FLAG else 0)
        buffer.putInt(pixelWidth)
        buffer.putInt(pixelHeight)
        buffer.putLong(presentationTime.value)
        buffer.putInt(presentationTime.timescale)
        buffer.putInt(data.size)
        buffer.put(data)
        return buffer.array()
    }

    companion object {
        const val HEADER_SIZE = 25
        private const val KEYFRAME_FLAG: Byte = 1

        fun decode(bytes: ByteArray): EncodedVideoFrame {
            if (bytes.size < HEADER_SIZE) throw VideoWireException.TruncatedHeader(bytes.size, HEADER_SIZE)
            val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
            val flags = buffer.get()
            val width = unsignedInt(buffer.getInt())
            val height = unsignedInt(buffer.getInt())
            val value = buffer.getLong()
            val timescale = buffer.getInt()
            val declared = unsignedInt(buffer.getInt())
            val actual = bytes.size - HEADER_SIZE
            if (declared != actual.toLong()) throw VideoWireException.LengthMismatch(declared, actual.toLong())
            return EncodedVideoFrame(
                isKeyframe = (flags.toInt() and KEYFRAME_FLAG.toInt()) != 0,
                pixelWidth = dimension(width),
                pixelHeight = dimension(height),
                presentationTime = VideoTimestamp(value, timescale),
                data = bytes.copyOfRange(HEADER_SIZE, bytes.size),
            )
        }

        private fun dimension(value: Long): Int {
            if (value > Int.MAX_VALUE) throw VideoWireException.DimensionOutOfRange(value)
            return value.toInt()
        }
    }
}

sealed class VideoWireException(message: String) : Exception(message) {
    class TruncatedHeader(val have: Int, val need: Int) :
        VideoWireException("video header truncated: have $have bytes, need $need")

    /** Worth failing on rather than trusting the outer frame length: a short read hands a truncated picture to the decoder. */
    class LengthMismatch(val declared: Long, val actual: Long) :
        VideoWireException("video frame declares $declared data bytes but carries $actual")

    class DimensionOutOfRange(val value: Long) :
        VideoWireException("video dimension $value does not fit a signed 32 bit size")
}

@Serializable
enum class AudioCodec {
    /** Raw 32-bit float PCM, interleaved channels. */
    @SerialName("pcmFloat32") PCM_FLOAT32,
}

@Serializable
data class AudioStreamConfig(
    val codec: AudioCodec,
    val sampleRate: Double,
    val channelCount: Int,
)

/** Interleaved little endian Float32 samples, [sampleCount] frames of [channelCount] values each. */
class EncodedAudioFrame(
    val sampleCount: Int,
    val channelCount: Int,
    val presentationTime: VideoTimestamp,
    val samples: ByteArray,
) {
    fun encode(): ByteArray {
        val buffer = ByteBuffer.allocate(HEADER_SIZE + samples.size).order(ByteOrder.BIG_ENDIAN)
        buffer.putInt(sampleCount)
        buffer.putInt(channelCount)
        buffer.putLong(presentationTime.value)
        buffer.putInt(presentationTime.timescale)
        buffer.put(samples)
        return buffer.array()
    }

    companion object {
        const val HEADER_SIZE = 20
        private const val MAX_CHANNELS = 32L
        private const val FLOAT32_BYTES = 4L

        fun decode(bytes: ByteArray): EncodedAudioFrame {
            if (bytes.size < HEADER_SIZE) throw AudioWireException.TruncatedHeader(bytes.size, HEADER_SIZE)
            val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
            val sampleCount = unsignedInt(buffer.getInt())
            val channelCount = unsignedInt(buffer.getInt())
            val value = buffer.getLong()
            val timescale = buffer.getInt()
            if (sampleCount == 0L) throw AudioWireException.InvalidSampleCount(sampleCount)
            if (channelCount !in 1L..MAX_CHANNELS) throw AudioWireException.InvalidChannelCount(channelCount)
            // Both factors are at most 2^32 and 32, so the product fits a Long without overflow.
            val declared = sampleCount * channelCount * FLOAT32_BYTES
            val actual = bytes.size - HEADER_SIZE
            if (declared != actual.toLong()) throw AudioWireException.LengthMismatch(declared, actual.toLong())
            return EncodedAudioFrame(
                sampleCount = sampleCount.toInt(),
                channelCount = channelCount.toInt(),
                presentationTime = VideoTimestamp(value, timescale),
                samples = bytes.copyOfRange(HEADER_SIZE, bytes.size),
            )
        }
    }
}

sealed class AudioWireException(message: String) : Exception(message) {
    class TruncatedHeader(val have: Int, val need: Int) :
        AudioWireException("audio header truncated: have $have bytes, need $need")

    class InvalidSampleCount(val count: Long) : AudioWireException("audio sample count $count must be at least 1")

    class InvalidChannelCount(val count: Long) :
        AudioWireException("audio channel count $count must be between 1 and 32")

    class LengthMismatch(val declared: Long, val actual: Long) :
        AudioWireException("audio frame expects $declared sample bytes but carries $actual")
}

private fun unsignedInt(value: Int): Long = value.toLong() and 0xFFFF_FFFFL
