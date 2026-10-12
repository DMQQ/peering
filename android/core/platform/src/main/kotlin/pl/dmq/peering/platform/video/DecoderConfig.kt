package pl.dmq.peering.platform.video

import pl.dmq.peering.wire.VideoCodec
import pl.dmq.peering.wire.VideoStreamConfig
import pl.dmq.peering.wire.csdFor

/** Everything a MediaCodec decoder needs for one stream, as plain values so the mapping can be tested on the JVM. */
data class DecoderConfig(
    val mimeType: String,
    val width: Int,
    val height: Int,
    val csd: List<ByteArray>,
    val options: Map<String, Int>,
) {
    companion object {
        /** MediaFormat keys, spelled out so this file needs no Android classes. */
        const val KEY_LOW_LATENCY = "low-latency"
        const val KEY_PRIORITY = "priority"
        const val KEY_OPERATING_RATE = "operating-rate"

        private const val LOW_LATENCY_MIN_SDK = 30
        private const val REALTIME_OPERATING_RATE = Short.MAX_VALUE.toInt()

        /** [sdkInt] is the platform level, passed in so the mapping is the same on every JVM run. */
        fun from(config: VideoStreamConfig, sdkInt: Int): DecoderConfig {
            require(config.isWithinLimits) { "video size ${config.pixelWidth}x${config.pixelHeight} is out of range" }
            return DecoderConfig(
                mimeType = mimeTypeFor(config.codec),
                width = config.pixelWidth,
                height = config.pixelHeight,
                csd = csdFor(wireName(config.codec), config.parameterSetBytes()),
                options = lowLatencyOptions(sdkInt),
            )
        }

        fun mimeTypeFor(codec: VideoCodec): String = when (codec) {
            VideoCodec.H264 -> "video/avc"
            VideoCodec.HEVC -> "video/hevc"
        }

        /** Low latency output is requested only where the platform knows the key, which is API 30 and later. */
        fun lowLatencyOptions(sdkInt: Int): Map<String, Int> = buildMap {
            if (sdkInt >= LOW_LATENCY_MIN_SDK) put(KEY_LOW_LATENCY, 1)
            put(KEY_PRIORITY, 0)
            put(KEY_OPERATING_RATE, REALTIME_OPERATING_RATE)
        }

        private fun wireName(codec: VideoCodec): String = when (codec) {
            VideoCodec.H264 -> "h264"
            VideoCodec.HEVC -> "hevc"
        }
    }
}
