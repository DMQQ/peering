@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.controller

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.session.flows.ScriptedPairingHost
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.ports.ReceivedDatagram
import pl.dmq.peering.wire.EncodedVideoFrame
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.RelayServerMessage
import pl.dmq.peering.wire.Token
import pl.dmq.peering.wire.VIDEO_TOKEN_SIZE
import pl.dmq.peering.wire.VideoCodec
import pl.dmq.peering.wire.VideoDirection
import pl.dmq.peering.wire.VideoSealer
import pl.dmq.peering.wire.VideoStreamConfig
import pl.dmq.peering.wire.VideoTimestamp
import pl.dmq.peering.wire.VideoTransportKind
import pl.dmq.peering.wire.VideoTransportRequest
import pl.dmq.peering.wire.WireJson

class PictureLaneTest {
    @Test
    fun aLanSessionDeliversConfigAndFramesFromTheControlConnectionToTheSink() = runTest {
        val mac = ScriptedMac()
        val rig = ControllerRig(backgroundScope, testScheduler, ConnectTarget.Lan(ControllerRig.LAN_ADDRESS, ScriptedPairingHost.HOST_ID), mac)
        rig.controller.connect()
        settle()

        mac.connections.single().deliver(Frame(MessageKind.VideoConfig, configPayload()))
        mac.connections.single().deliver(Frame(MessageKind.VideoFrame, framePayload(seed = 1, size = 500)))
        settle()

        assertEquals(1, rig.sink.configs.size)
        assertArrayEquals(ByteArray(500) { 1 }, rig.sink.frames.single().data)
        assertEquals(PictureState.Live, rig.controller.state.value.picture)
    }

    @Test
    fun aDecoderThatGaveUpShowsAsAFailedPictureWithItsOwnCode() = runTest {
        val mac = ScriptedMac()
        val rig = ControllerRig(backgroundScope, testScheduler, ConnectTarget.Lan(ControllerRig.LAN_ADDRESS, ScriptedPairingHost.HOST_ID), mac)
        rig.controller.connect()
        settle()
        mac.connections.single().deliver(Frame(MessageKind.VideoConfig, configPayload()))
        rig.sink.decoderFailed = true

        mac.connections.single().deliver(Frame(MessageKind.VideoFrame, framePayload(seed = 1, size = 500)))
        settle()

        assertEquals(PictureState.Failed(PictureFailure.DecoderFailed), rig.controller.state.value.picture)
    }

    @Test
    fun aConfigWithAnAbsurdSizeNeverReachesTheSink() = runTest {
        val mac = ScriptedMac()
        val rig = ControllerRig(backgroundScope, testScheduler, ConnectTarget.Lan(ControllerRig.LAN_ADDRESS, ScriptedPairingHost.HOST_ID), mac)
        rig.controller.connect()
        settle()

        mac.connections.single().deliver(Frame(MessageKind.VideoConfig, configPayload(width = 100_000, height = 1_080)))
        mac.connections.single().deliver(Frame(MessageKind.VideoConfig, configPayload(width = 0, height = 0)))
        settle()

        assertEquals(0, rig.sink.configs.size)
    }

    @Test
    fun sealedDatagramsOnTheRelayReachTheSink() = runTest {
        val rig = relayRig()
        grantSession(rig)
        rig.controller.connect()
        settle()

        val sealer = VideoSealer(rig.mac.videoSecret, VideoDirection.HostToClient, VIDEO_TOKEN)
        for ((kind, payload) in listOf(MessageKind.VideoConfig to configPayload(), MessageKind.VideoFrame to framePayload(seed = 3, size = 3_000))) {
            for (sealed in sealer.seal(kind, payload)) {
                rig.datagrams.deliver(ReceivedDatagram(VIDEO_PEER, sealed.copyOfRange(VIDEO_TOKEN_SIZE, sealed.size)))
            }
        }
        settle()

        assertEquals(1, rig.sink.configs.size)
        assertArrayEquals(ByteArray(3_000) { 3 }, rig.sink.frames.single().data)
        assertEquals(PictureState.Live, rig.controller.state.value.picture)
    }

    @Test
    fun aSilentDatagramLaneFallsBackToTheControlChannelAndShowsIt() = runTest {
        val rig = relayRig()
        grantSession(rig)
        rig.controller.connect()
        settle()

        advanceTimeBy(5_000)
        runCurrent()

        val requests = rig.mac.connections.single().phoneFrames.ofKind(MessageKind.VideoTransport)
            .map { WireJson.decodeFromString(VideoTransportRequest.serializer(), it.payload.decodeToString()) }
        assertEquals(listOf(VideoTransportKind.CONTROL), requests.map { it.transport })
        assertEquals(PictureState.Fallback, rig.controller.state.value.picture)
    }

    private fun TestScope.relayRig(): ControllerRig = ControllerRig(
        backgroundScope,
        testScheduler,
        ConnectTarget.Relay(ScriptedPairingHost.HOST_ID),
    )

    private fun grantSession(rig: ControllerRig) {
        rig.signalling.reply(
            RelayServerMessage.SessionReady(
                controlHost = "control.example",
                controlPort = 4431,
                videoHost = VIDEO_PEER.host,
                videoPort = VIDEO_PEER.port,
                controlToken = Token(ByteArray(Token.SIZE) { 1 }),
                videoToken = Token(VIDEO_TOKEN),
            ),
        )
    }

    private fun configPayload(width: Int = 1_920, height: Int = 1_080): ByteArray = WireJson.encodeToString(
        VideoStreamConfig.serializer(),
        VideoStreamConfig(
            sourceID = "display-1",
            codec = VideoCodec.H264,
            pixelWidth = width,
            pixelHeight = height,
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

    private suspend fun TestScope.settle() {
        advanceTimeBy(100)
        runCurrent()
    }

    private companion object {
        val VIDEO_PEER = PeerAddress("video.example", 4500)
        val VIDEO_TOKEN = ByteArray(Token.SIZE) { 2 }
    }
}
