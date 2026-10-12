package pl.dmq.peering.session.connection

import kotlinx.serialization.encodeToString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.testing.FakeClock
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.PingPayload
import pl.dmq.peering.wire.WireJson

class LivenessMonitorTest {
    private val clock = FakeClock()
    private val monitor = LivenessMonitor(clock)

    private fun sequenceOf(frame: Frame): Long =
        WireJson.decodeFromString(PingPayload.serializer(), frame.payload.decodeToString()).sequence

    private fun pong(sequence: Long?): Frame {
        val payload = if (sequence == null) {
            ByteArray(0)
        } else {
            WireJson.encodeToString(PingPayload.serializer(), PingPayload(sequence)).toByteArray(Charsets.UTF_8)
        }
        return Frame(MessageKind.Pong, payload)
    }

    @Test
    fun pingsAreNumberedFromOneAndCarryTheirSequence() {
        assertEquals(1L, sequenceOf(monitor.nextPing()))
        assertEquals(2L, sequenceOf(monitor.nextPing()))
    }

    @Test
    fun aPongIsTimedAgainstItsOwnPing() {
        val first = monitor.nextPing()
        clock.advance(0.25)

        assertEquals(250.0, monitor.onPong(pong(sequenceOf(first)))!!, 1e-9)
    }

    @Test
    fun aPongMatchesItsOwnPingWhenAnotherIsStillOpen() {
        val first = monitor.nextPing()
        clock.advance(0.1)
        val second = monitor.nextPing()
        clock.advance(0.3)

        assertEquals(300.0, monitor.onPong(pong(sequenceOf(second)))!!, 1e-9)
        assertNull(monitor.onPong(pong(sequenceOf(first))))
    }

    @Test
    fun aLatePongForAnEarlierPingIsDiscardedOnceANewerOneAnswered() {
        val first = monitor.nextPing()
        val second = monitor.nextPing()
        monitor.onPong(pong(sequenceOf(second)))

        assertNull(monitor.onPong(pong(sequenceOf(first))))
    }

    @Test
    fun aPongWithAnUnknownSequenceIsDiscarded() {
        monitor.nextPing()

        assertNull(monitor.onPong(pong(sequence = 999)))
    }

    @Test
    fun anEmptyPongIsReadAsTheOldestOpenPing() {
        monitor.nextPing()
        clock.advance(0.5)

        assertEquals(500.0, monitor.onPong(pong(sequence = null))!!, 1e-9)
    }

    @Test
    fun aPingOlderThanTheFourUnansweredOnesIsNeverReported() {
        val oldest = monitor.nextPing()
        repeat(4) { monitor.nextPing() }

        assertNull(monitor.onPong(pong(sequenceOf(oldest))))
    }

    @Test
    fun aFrameThatIsNotAPongIsIgnored() {
        val ping = monitor.nextPing()

        assertNull(monitor.onPong(Frame(MessageKind.Ping, ping.payload)))
    }

    @Test
    fun theSmoothedLatencyIsTheMedianSoOneStalledPingDoesNotDominate() {
        listOf(0.1, 0.9, 0.2).forEach { seconds ->
            val ping = monitor.nextPing()
            clock.advance(seconds)
            monitor.onPong(pong(sequenceOf(ping)))
        }

        assertEquals(200.0, monitor.smoothedLatencyMillis()!!, 1e-9)
    }

    @Test
    fun anEvenNumberOfSamplesAveragesTheMiddlePair() {
        listOf(0.1, 0.3).forEach { seconds ->
            val ping = monitor.nextPing()
            clock.advance(seconds)
            monitor.onPong(pong(sequenceOf(ping)))
        }

        assertEquals(200.0, monitor.smoothedLatencyMillis()!!, 1e-9)
    }

    @Test
    fun onlyTheLastEightRoundTripsCountTowardTheLatency() {
        val slow = monitor.nextPing()
        clock.advance(1.0)
        monitor.onPong(pong(sequenceOf(slow)))
        repeat(8) {
            val ping = monitor.nextPing()
            clock.advance(0.05)
            monitor.onPong(pong(sequenceOf(ping)))
        }

        assertEquals(50.0, monitor.smoothedLatencyMillis()!!, 1e-9)
    }

    @Test
    fun noLatencyIsReportedBeforeTheFirstPong() {
        assertNull(monitor.smoothedLatencyMillis())
    }

    @Test
    fun silenceCountsFromWhenTheMonitorWasMadeUntilTheLastPong() {
        clock.advance(5.0)
        assertEquals(5.0, monitor.silenceSeconds(clock.monotonicSeconds()), 1e-9)

        val ping = monitor.nextPing()
        monitor.onPong(pong(sequenceOf(ping)))
        clock.advance(3.0)
        assertEquals(3.0, monitor.silenceSeconds(clock.monotonicSeconds()), 1e-9)
    }

    @Test
    fun resettingTheSilenceCountsFromNow() {
        clock.advance(20.0)

        monitor.resetSilence()

        assertEquals(0.0, monitor.silenceSeconds(clock.monotonicSeconds()), 1e-9)
    }

    @Test
    fun aConnectionIsSilentOnlyPastItsLimit() {
        clock.advance(10.0)
        assertFalse(monitor.isSilent(clock.monotonicSeconds(), limitSeconds = 10.0))

        clock.advance(0.5)
        assertTrue(monitor.isSilent(clock.monotonicSeconds(), limitSeconds = 10.0))
    }

    @Test
    fun anUnmatchedPongStillCountsAsProofTheConnectionIsAlive() {
        clock.advance(9.0)
        monitor.onPong(pong(sequence = 404))
        clock.advance(9.0)

        assertFalse(monitor.isSilent(clock.monotonicSeconds(), limitSeconds = 10.0))
    }

    @Test
    fun thePingIntervalIsOneSecond() {
        assertEquals(1.0, LivenessMonitor.PING_INTERVAL_SECONDS, 0.0)
    }
}
