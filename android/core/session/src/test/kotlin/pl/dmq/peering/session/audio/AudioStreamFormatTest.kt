package pl.dmq.peering.session.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.wire.AudioCodec
import pl.dmq.peering.wire.AudioStreamConfig

class AudioStreamFormatTest {
    private fun config(rate: Double = 48_000.0, channels: Int = 2) =
        AudioStreamConfig(AudioCodec.PCM_FLOAT32, rate, channels)

    @Test
    fun aStereoStreamPlaysAsStereo() {
        val format = AudioStreamFormat.of(config())
        assertEquals(48_000, format?.sampleRate)
        assertEquals(2, format?.outputChannels)
    }

    @Test
    fun aSurroundStreamPlaysAsItsFrontPair() {
        val format = AudioStreamFormat.of(config(channels = 6))
        assertEquals(6, format?.sourceChannels)
        assertEquals(2, format?.outputChannels)
    }

    @Test
    fun aMonoStreamStaysMono() {
        assertEquals(1, AudioStreamFormat.of(config(channels = 1))?.outputChannels)
    }

    @Test
    fun ratesOutsideTheWireRangeAreRefused() {
        assertNull(AudioStreamFormat.of(config(rate = 7_999.0)))
        assertNull(AudioStreamFormat.of(config(rate = 384_001.0)))
        assertNull(AudioStreamFormat.of(config(rate = Double.NaN)))
        assertNotNull(AudioStreamFormat.of(config(rate = 8_000.0)))
    }

    @Test
    fun channelCountsOutsideTheWireRangeAreRefused() {
        assertNull(AudioStreamFormat.of(config(channels = 0)))
        assertNull(AudioStreamFormat.of(config(channels = 33)))
    }
}
