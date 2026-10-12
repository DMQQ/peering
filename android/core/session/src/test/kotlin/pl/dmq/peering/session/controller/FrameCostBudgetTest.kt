package pl.dmq.peering.session.controller

import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.connection.LivenessMonitor
import pl.dmq.peering.session.connection.SessionCommands
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.terminal.TerminalSessions
import pl.dmq.peering.session.testing.FakeVideoSink
import pl.dmq.peering.session.video.SourceSelection
import pl.dmq.peering.session.video.VideoLanes
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.ServerHello
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalSessionInfo
import pl.dmq.peering.wire.VideoChunkEncoder
import pl.dmq.peering.wire.VideoChunkReassembler
import pl.dmq.peering.wire.WireJson

/**
 * The frame router, the terminal byte parser and video reassembly share state with the UI and run on Main, so they cannot
 * move off it. This keeps their per frame cost small enough to stay there. The budget is generous (a frame is 16 ms at
 * 60 fps) because a CI machine is slow and shared; a real regression is far beyond it.
 */
class FrameCostBudgetTest {
    private val clock = object : Clock {
        override fun monotonicSeconds() = 0.0

        override fun unixSeconds() = 0L
    }

    private fun medianMillis(work: () -> Unit): Double {
        repeat(WARMUP) { work() }
        val samples = List(SAMPLES) {
            val start = System.nanoTime()
            work()
            (System.nanoTime() - start) / NANOS_PER_MILLI
        }
        return samples.sorted()[SAMPLES / 2]
    }

    @Test
    fun routingA64KibTerminalOutputEventStaysUnderTheBudget() {
        val terminals = TerminalSessions(send = {})
        terminals.onEvent(TerminalEvent.Snapshot(listOf(TerminalSessionInfo("t", "t", true, 120, 40))))
        val router = FrameRouter(
            liveness = LivenessMonitor(clock),
            commands = SessionCommands(ServerHello(serverID = "s", hostName = "h", protocolVersion = 20, alreadyPaired = true)),
            lanes = VideoLanes(FakeVideoSink(), clock, PeerAddress("relay", 1), ByteArray(16)),
            selection = SourceSelection(),
            agent = null,
            files = null,
            terminals = terminals,
        )
        val text = "plain \u001B[31mred\u001B[0m \u001B[1;34mbold blue\u001B[0m with some words to wrap past the margin\r\n"
        val raw = text.repeat(MAX_RAW_BYTES / text.length).toByteArray()
        val event = TerminalEvent.Output("t", Base64.getEncoder().encodeToString(raw))
        val payload = WireJson.encodeToString(TerminalEvent.serializer(), event).toByteArray()
        assertTrue("the frame is the size under test", payload.size in 60_000..64 * 1024)

        val millis = medianMillis { router.route(Frame(MessageKind.TerminalEvent, payload)) }

        assertTrue("routing took $millis ms against a budget of $BUDGET_MILLIS ms", millis < BUDGET_MILLIS)
    }

    @Test
    fun reassemblingA64KibPictureFromControlChunksStaysUnderTheBudget() {
        val whole = ByteArray(64 * 1024) { (it % 251).toByte() }
        val reassembler = VideoChunkReassembler()
        var frameId = 0L

        val millis = medianMillis {
            frameId += 1
            val numbered = VideoChunkEncoder.encode(MessageKind.VideoKey, whole, frameId, CHUNK_SIZE)
            assertEquals(4, numbered.size)
            val joined = numbered.mapNotNull { reassembler.ingest(it) }.single()
            assertEquals(whole.size, joined.payload.size)
        }

        assertTrue("reassembly took $millis ms against a budget of $BUDGET_MILLIS ms", millis < BUDGET_MILLIS)
    }

    private companion object {
        const val WARMUP = 20
        const val SAMPLES = 15
        const val BUDGET_MILLIS = 20.0
        const val NANOS_PER_MILLI = 1_000_000.0
        const val MAX_RAW_BYTES = 46_000
        const val CHUNK_SIZE = 16 * 1024
    }
}
