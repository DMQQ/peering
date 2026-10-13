package pl.dmq.peering.session.audio

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.wire.AudioCodec
import pl.dmq.peering.wire.AudioStreamConfig
import pl.dmq.peering.wire.EncodedAudioFrame
import pl.dmq.peering.wire.VideoTimestamp
import java.nio.ByteBuffer
import java.nio.ByteOrder

class PcmFramesTest {
    private fun format(channels: Int) =
        checkNotNull(AudioStreamFormat.of(AudioStreamConfig(AudioCodec.PCM_FLOAT32, 48_000.0, channels)))

    private fun frame(channels: Int, vararg samples: Float): EncodedAudioFrame {
        val bytes = ByteBuffer.allocate(samples.size * 4).order(ByteOrder.LITTLE_ENDIAN)
        samples.forEach(bytes::putFloat)
        return EncodedAudioFrame(samples.size / channels, channels, VideoTimestamp(0, 48_000), bytes.array())
    }

    @Test
    fun stereoSamplesKeepTheirInterleaving() {
        val out = PcmFrames.toOutput(frame(2, 0.1f, -0.1f, 0.2f, -0.2f), format(2))
        assertArrayEquals(floatArrayOf(0.1f, -0.1f, 0.2f, -0.2f), out, 0f)
    }

    @Test
    fun surroundKeepsOnlyTheFrontPairOfEachFrame() {
        val out = PcmFrames.toOutput(frame(3, 0.1f, 0.2f, 0.9f, 0.3f, 0.4f, 0.9f), format(3))
        assertArrayEquals(floatArrayOf(0.1f, 0.2f, 0.3f, 0.4f), out, 0f)
    }

    @Test
    fun notANumberPlaysAsSilenceAndLoudSamplesAreClamped() {
        val out = PcmFrames.toOutput(frame(1, Float.NaN, 4f, -4f), format(1))
        assertArrayEquals(floatArrayOf(0f, 1f, -1f), out, 0f)
    }

    @Test
    fun aFrameOfAnotherChannelCountIsRefused() {
        assertNull(PcmFrames.toOutput(frame(1, 0.5f), format(2)))
    }
}
