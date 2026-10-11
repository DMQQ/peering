package pl.dmq.peering.platform.video

import java.util.Base64
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import pl.dmq.peering.wire.AnnexBException
import pl.dmq.peering.wire.VideoCodec
import pl.dmq.peering.wire.VideoStreamConfig

class DecoderConfigTest {
    private val startCode = byteArrayOf(0, 0, 0, 1)

    private fun parameterSet(seed: Int): ByteArray = ByteArray(6) { (seed + it).toByte() }

    private fun config(codec: VideoCodec, sets: List<ByteArray>, width: Int = 1920, height: Int = 1080) =
        VideoStreamConfig(
            sourceID = "display-1",
            codec = codec,
            pixelWidth = width,
            pixelHeight = height,
            parameterSets = sets.map { Base64.getEncoder().encodeToString(it) },
        )

    @Test
    fun h264UsesAvcMimeTypeAndTwoCodecBuffers() {
        val sps = parameterSet(1)
        val pps = parameterSet(2)

        val decoder = DecoderConfig.from(config(VideoCodec.H264, listOf(sps, pps)), sdkInt = 34)

        assertEquals("video/avc", decoder.mimeType)
        assertEquals(2, decoder.csd.size)
        assertArrayEquals(startCode + sps, decoder.csd[0])
        assertArrayEquals(startCode + pps, decoder.csd[1])
    }

    @Test
    fun hevcUsesHevcMimeTypeAndOneCodecBufferHoldingAllThreeSets() {
        val vps = parameterSet(1)
        val sps = parameterSet(2)
        val pps = parameterSet(3)

        val decoder = DecoderConfig.from(config(VideoCodec.HEVC, listOf(vps, sps, pps)), sdkInt = 34)

        assertEquals("video/hevc", decoder.mimeType)
        assertEquals(1, decoder.csd.size)
        assertArrayEquals(startCode + vps + startCode + sps + startCode + pps, decoder.csd[0])
    }

    @Test
    fun sizeComesFromTheStreamConfig() {
        val decoder = DecoderConfig.from(config(VideoCodec.H264, listOf(parameterSet(1), parameterSet(2)), 2560, 1440), 34)

        assertEquals(2560, decoder.width)
        assertEquals(1440, decoder.height)
    }

    @Test
    fun zeroSizeIsRefused() {
        assertThrows(IllegalArgumentException::class.java) {
            DecoderConfig.from(config(VideoCodec.H264, listOf(parameterSet(1), parameterSet(2)), 0, 1080), 34)
        }
    }

    @Test
    fun wrongNumberOfParameterSetsIsRefused() {
        assertThrows(AnnexBException::class.java) {
            DecoderConfig.from(config(VideoCodec.H264, listOf(parameterSet(1))), 34)
        }
    }

    @Test
    fun lowLatencyKeyIsSetFromApiThirty() {
        val options = DecoderConfig.lowLatencyOptions(sdkInt = 30)

        assertEquals(1, options[DecoderConfig.KEY_LOW_LATENCY])
    }

    @Test
    fun lowLatencyKeyIsNotSetBelowApiThirty() {
        val options = DecoderConfig.lowLatencyOptions(sdkInt = 29)

        assertEquals(null, options[DecoderConfig.KEY_LOW_LATENCY])
    }

    @Test
    fun priorityIsRealtimeAndOperatingRateIsMaximal() {
        val options = DecoderConfig.lowLatencyOptions(sdkInt = 29)

        assertEquals(0, options[DecoderConfig.KEY_PRIORITY])
        assertEquals(Short.MAX_VALUE.toInt(), options[DecoderConfig.KEY_OPERATING_RATE])
    }
}
