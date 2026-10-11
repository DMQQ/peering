package pl.dmq.peering.session.connection

import kotlinx.serialization.encodeToString
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.PingPayload
import pl.dmq.peering.wire.WireJson

/**
 * Keeps the control connection honest: each ping is numbered, each pong is timed against its own ping, and the time
 * since the last pong says whether the connection has gone silent. The baseline is the moment the monitor was made,
 * so a host that never answers the first ping is still judged.
 */
class LivenessMonitor(private val clock: Clock) {
    private val ledger = PingLedger()
    private val recentRoundTripsMillis = ArrayDeque<Double>()
    private var lastReplyAtSeconds: Double = clock.monotonicSeconds()

    fun nextPing(): Frame {
        val ping = ledger.record(clock.monotonicSeconds())
        val payload = WireJson.encodeToString(PingPayload.serializer(), PingPayload(ping.sequence))
        return Frame(MessageKind.Ping, payload.toByteArray(Charsets.UTF_8))
    }

    /**
     * Returns the round trip in milliseconds when the pong answers a ping still in flight, and null otherwise. Any pong
     * counts as proof the connection is alive, even one that is late or unknown.
     */
    fun onPong(frame: Frame): Double? {
        if (frame.kind != MessageKind.Pong) return null
        val now = clock.monotonicSeconds()
        lastReplyAtSeconds = now

        val sequence = HandshakeFrames.decode(frame, PingPayload.serializer())?.sequence
        val ping = ledger.answered(sequence) ?: return null
        val roundTripMillis = (now - ping.sentAtSeconds) * MILLIS_PER_SECOND
        recentRoundTripsMillis.addLast(roundTripMillis)
        if (recentRoundTripsMillis.size > SAMPLE_COUNT) recentRoundTripsMillis.removeFirst()
        return roundTripMillis
    }

    /** The median of the last eight round trips, or null before the first. A median keeps one stalled ping from dominating. */
    fun smoothedLatencyMillis(): Double? {
        if (recentRoundTripsMillis.isEmpty()) return null
        val sorted = recentRoundTripsMillis.sorted()
        val middle = sorted.size / 2
        return if (sorted.size % 2 == 1) sorted[middle] else (sorted[middle - 1] + sorted[middle]) / 2
    }

    fun silenceSeconds(nowSeconds: Double): Double = nowSeconds - lastReplyAtSeconds

    fun isSilent(nowSeconds: Double, limitSeconds: Double): Boolean = silenceSeconds(nowSeconds) > limitSeconds

    companion object {
        const val PING_INTERVAL_SECONDS = 1.0

        private const val SAMPLE_COUNT = 8
        private const val MILLIS_PER_SECOND = 1000.0
    }
}
