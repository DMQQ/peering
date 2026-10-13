package pl.dmq.peering.session.flows

import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.relay.DirectPathState
import pl.dmq.peering.session.relay.RelayConnect
import pl.dmq.peering.session.relay.RelaySessionException
import pl.dmq.peering.session.testing.FakeIdentity
import pl.dmq.peering.session.testing.FakeSignalling
import pl.dmq.peering.wire.EncodedVideoFrame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.RelayServerMessage
import pl.dmq.peering.wire.VideoCodec
import pl.dmq.peering.wire.VideoStreamConfig
import pl.dmq.peering.wire.VideoTimestamp
import pl.dmq.peering.wire.VideoTransportKind
import pl.dmq.peering.wire.WireJson

class RelayFlowTest {
    @Test
    fun aRelayedSessionReachesReadyAndGetsTheVideoKey() = runTest {
        val rig = RelayRig(backgroundScope, testScheduler)

        rig.connect()

        assertEquals(16, rig.session.controlHandoff().token.size)
        assertTrue(rig.handshakeReady)
        assertEquals(
            listOf(MessageKind.ConnectionRole, MessageKind.ClientHello, MessageKind.VideoKeyRequest),
            rig.controlWritten.map { it.kind },
        )
        assertEquals(rig.relayAddress, rig.datagrams.sent.single().first)
        assertArrayEquals(rig.session.videoTokenBytes, rig.datagrams.sent.single().second)
    }

    @Test
    fun sealedDatagramsDeliverTheConfigAndAFrameThatSpansSeveralDatagrams() = runTest {
        val rig = RelayRig(backgroundScope, testScheduler)
        rig.connect()

        rig.sendDatagram(MessageKind.VideoConfig, configPayload())
        rig.sendDatagram(MessageKind.VideoFrame, framePayload(seed = 1, size = 3_000))
        rig.settle()

        assertEquals(1, rig.sink.configs.size)
        assertEquals(1, rig.sink.frames.size)
        assertArrayEquals(ByteArray(3_000) { 1 }, rig.sink.frames.single().data)
        assertEquals(0, rig.lanes.failedDatagrams)
    }

    @Test
    fun aSilentDatagramLaneRequestsTheControlChannelAfterThreeSeconds() = runTest {
        val rig = fallenBackRig()

        assertEquals(listOf(VideoTransportKind.CONTROL), rig.transportRequests())
        assertEquals(VideoTransportKind.CONTROL, rig.lanes.delivery.transport)
        assertTrue(rig.lanes.delivery.fellBack)
    }

    @Test
    fun controlChunksDeliverPicturesWhileTheLaneIsOnTheFallback() = runTest {
        val rig = fallenBackRig()

        advanceTo(4_500)
        rig.sendControlPicture(MessageKind.VideoFrame, framePayload(seed = 2, size = 2_000), frameId = 9)
        rig.settle()

        assertEquals(2, rig.sink.frames.size)
        assertArrayEquals(ByteArray(2_000) { 2 }, rig.sink.frames.last().data)
        assertEquals(VideoTransportKind.CONTROL, rig.lanes.delivery.transport)
    }

    @Test
    fun twoPrimaryPicturesReturnTheLaneToPrimary() = runTest {
        val rig = fallenBackRig()
        advanceTo(4_500)
        rig.sendControlPicture(MessageKind.VideoFrame, framePayload(seed = 2, size = 2_000), frameId = 9)
        rig.settle()

        advanceTo(9_000)
        rig.sendDatagram(MessageKind.VideoFrame, framePayload(seed = 3, size = 100))
        rig.sendDatagram(MessageKind.VideoFrame, framePayload(seed = 4, size = 100))
        rig.settle()
        advanceTo(9_500)

        assertEquals(listOf(VideoTransportKind.CONTROL, VideoTransportKind.PRIMARY), rig.transportRequests())
        assertEquals(VideoTransportKind.PRIMARY, rig.lanes.delivery.transport)
    }

    @Test
    fun aHostThatDeclinesTheControlRequestGetsItRepeatedAfterFiveSeconds() = runTest {
        val rig = fallenBackRig()

        advanceTo(8_999)
        assertEquals(listOf(VideoTransportKind.CONTROL), rig.transportRequests())

        advanceTo(9_000)
        assertEquals(listOf(VideoTransportKind.CONTROL, VideoTransportKind.CONTROL), rig.transportRequests())
    }

    @Test
    fun aDatagramFromAPeerAddressOpensTheDirectPath() = runTest {
        val rig = RelayRig(backgroundScope, testScheduler)
        rig.connect()
        val peer = PeerAddress("198.51.100.9", 40_000)
        rig.prober.onPeerAddress(peer.host, peer.port)
        assertEquals(DirectPathState.Probing(peer), rig.prober.state)

        rig.sendDatagram(MessageKind.VideoConfig, configPayload())
        rig.settle()
        assertEquals(DirectPathState.Probing(peer), rig.prober.state)

        rig.sendDatagram(MessageKind.VideoFrame, framePayload(seed = 5, size = 100), from = peer)
        rig.settle()
        assertEquals(DirectPathState.Open(peer), rig.prober.state)
        assertEquals(peer, rig.prober.destination)
    }

    @Test
    fun aQuotaExceededReplyFromTheRelaySurfaces() = runTest {
        val signalling = FakeSignalling()
        signalling.reply(RelayServerMessage.Error("quotaExceeded", "free time used"))
        val relay = RelayConnect(signalling, FakeIdentity(), TestSchedulerClock(testScheduler))

        val failure = runCatching { relay.requestSession(ScriptedPairingHost.HOST_ID, CLIENT_ID) }.exceptionOrNull()

        assertEquals(RelaySessionException.QuotaExceeded, failure)
    }

    /** A connected session whose picture arrived at one second, has gone silent, and has asked for the control channel at four. */
    private suspend fun TestScope.fallenBackRig(): RelayRig {
        val rig = RelayRig(backgroundScope, testScheduler)
        rig.connect()
        advanceTo(1_000)
        rig.sendDatagram(MessageKind.VideoConfig, configPayload())
        rig.sendDatagram(MessageKind.VideoFrame, framePayload(seed = 1, size = 100))
        rig.settle()
        advanceTo(3_999)
        assertEquals(emptyList<VideoTransportKind>(), rig.transportRequests())
        advanceTo(4_000)
        return rig
    }

    private suspend fun TestScope.advanceTo(milliseconds: Long) {
        advanceTimeBy(milliseconds - testScheduler.currentTime)
        runCurrent()
    }

    private fun configPayload(): ByteArray = WireJson.encodeToString(
        VideoStreamConfig.serializer(),
        VideoStreamConfig(
            sourceID = "display-1",
            codec = VideoCodec.H264,
            pixelWidth = 1_920,
            pixelHeight = 1_080,
            parameterSets = listOf("Z0IAHo="),
        ),
    ).toByteArray(Charsets.UTF_8)

    private fun framePayload(seed: Int, size: Int): ByteArray = EncodedVideoFrame(
        isKeyframe = true,
        pixelWidth = 1_920,
        pixelHeight = 1_080,
        presentationTime = VideoTimestamp(seed.toLong(), 90_000),
        data = ByteArray(size) { seed.toByte() },
    ).encode()

    private companion object {
        const val CLIENT_ID = "11111111-2222-4333-8444-555555555555"
    }
}
