package pl.dmq.peering.session.controller

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.history.ByteTally
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.FrameEncoder
import pl.dmq.peering.wire.MAX_CONTROL_PAYLOAD
import pl.dmq.peering.wire.MessageKind

class ReaderLoopTest {
    private suspend fun read(vararg frames: Frame, limitApplies: Boolean = true): List<Frame> {
        val out = Channel<Frame>(Channel.UNLIMITED)
        val bytes = frames.map { FrameEncoder.encode(it.kind, it.payload) }
        ReaderLoop(flowOf(*bytes.toTypedArray()), out, ByteTally(), { limitApplies }) { }.run()
        return buildList { for (frame in out) add(frame) }
    }

    @Test
    fun aControlPayloadOverSixtyFourKibIsDroppedAndTheNextFrameStillArrives() = runTest {
        val oversize = Frame(MessageKind.AgentEvent, ByteArray(MAX_CONTROL_PAYLOAD + 1))
        val small = Frame(MessageKind.Notice, "{}".toByteArray())

        assertEquals(listOf(small), read(oversize, small))
    }

    @Test
    fun aLargeControlPayloadIsKeptOnceTheHandshakeIsDone() = runTest {
        val catalogue = Frame(MessageKind.Catalog, ByteArray(MAX_CONTROL_PAYLOAD * 3))

        assertEquals(listOf(catalogue), read(catalogue, limitApplies = false))
    }

    @Test
    fun aPayloadOfExactlySixtyFourKibIsKept() = runTest {
        val limit = Frame(MessageKind.AgentEvent, ByteArray(MAX_CONTROL_PAYLOAD))

        assertEquals(listOf(limit), read(limit))
    }

    @Test
    fun aPictureFrameLargerThanSixtyFourKibIsKept() = runTest {
        val picture = Frame(MessageKind.VideoFrame, ByteArray(MAX_CONTROL_PAYLOAD * 4))

        assertEquals(listOf(picture), read(picture))
    }

    @Test
    fun theInboundChannelStopsTheReaderWhenFullAndResumesWhenDrained() = runTest {
        val total = ReaderLoop.INBOUND_CAPACITY + 50
        val frame = FrameEncoder.encode(MessageKind.Notice, "{}".toByteArray())
        val inbound = ReaderLoop.inbound()
        val reading = launch { ReaderLoop(flowOf(*Array(total) { frame }), inbound, ByteTally()) { }.run() }

        runCurrent()
        assertTrue(reading.isActive)

        var received = 0
        for (arrived in inbound) {
            received += 1
            if (received == total) break
        }
        reading.join()
        assertEquals(total, received)
    }
}
