package pl.dmq.peering.session.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.wire.AudioCodec
import pl.dmq.peering.wire.AudioStreamConfig

class AudioBacklogTest {
    // 8000 Hz mono: eight samples make a millisecond.
    private val format = checkNotNull(AudioStreamFormat.of(AudioStreamConfig(AudioCodec.PCM_FLOAT32, 8_000.0, 1)))
    private val backlog = AudioBacklog(format, prebufferMillis = 20, maxMillis = 50)

    private fun millis(count: Int) = FloatArray(count * 8) { it.toFloat() }

    @Test
    fun nothingPlaysUntilThePrebufferHasGathered() {
        backlog.offer(millis(10))
        assertNull(backlog.poll())
        backlog.offer(millis(10))
        assertNotNull(backlog.poll())
    }

    @Test
    fun soundComesOutInTheOrderItWentIn() {
        val first = millis(10)
        val second = FloatArray(80) { -1f }
        backlog.offer(first)
        backlog.offer(second)
        assertEquals(first, backlog.poll())
        assertEquals(second, backlog.poll())
    }

    @Test
    fun runningDryCountsAnUnderrunAndWaitsForTheBufferAgain() {
        backlog.offer(millis(20))
        backlog.poll()
        assertNull(backlog.poll())
        assertEquals(1, backlog.underruns)
        backlog.offer(millis(10))
        assertNull(backlog.poll())
    }

    @Test
    fun aQueueOverTheLimitDropsItsOldestSoundDownToThePrebuffer() {
        repeat(6) { backlog.offer(millis(10)) }
        assertEquals(40L * 8, backlog.droppedFrames)
        var left = 0
        while (backlog.poll() != null) left += 1
        assertEquals(2, left)
    }

    @Test
    fun clearingEmptiesItAndPrimesAgain() {
        backlog.offer(millis(30))
        backlog.clear()
        assertNull(backlog.poll())
        assertEquals(0, backlog.underruns)
    }
}
