@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.controller

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.flows.ScriptedPairingHost
import pl.dmq.peering.wire.ConnectionRole
import pl.dmq.peering.wire.EncodedVideoFrame
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.VideoCodec
import pl.dmq.peering.wire.VideoStreamConfig
import pl.dmq.peering.wire.VideoTimestamp
import pl.dmq.peering.wire.WireJson

class LanPictureTest {
    @Test
    fun aLocalSessionOpensASecondConnectionAndSendsTheVideoRoleFirst() = runTest {
        val rig = lanRig()
        rig.controller.connect()
        settle()

        assertEquals(listOf(ControlRoute.Direct(ControllerRig.LAN_ADDRESS), ControlRoute.Video(ControllerRig.LAN_ADDRESS)), rig.routes)
        val role = rig.videoConnections.single().phoneFrames.first()
        assertEquals(MessageKind.ConnectionRole, role.kind)
        assertArrayEquals(byteArrayOf(ConnectionRole.Video.byte.toByte()), role.payload)
        assertEquals(1, rig.videoConnections.single().phoneFrames.size)
    }

    @Test
    fun theVideoConnectionOpensOnlyAfterTheControlSessionIsReady() = runTest {
        val rig = lanRig()
        rig.mac.silentOn = MessageKind.ClientHello
        rig.controller.connect()
        settle()

        assertTrue(rig.videoConnections.isEmpty())
    }

    @Test
    fun framesOnTheVideoConnectionReachTheSinkAndMakeThePictureLive() = runTest {
        val rig = lanRig()
        rig.controller.connect()
        settle()

        val video = rig.videoConnections.single()
        video.deliver(Frame(MessageKind.VideoConfig, configPayload("display-1")))
        video.deliver(Frame(MessageKind.VideoFrame, framePayload(seed = 4, size = 900)))
        settle()

        assertEquals(1, rig.sink.configs.size)
        assertArrayEquals(ByteArray(900) { 4 }, rig.sink.frames.single().data)
        assertEquals(PictureState.Live, rig.controller.state.value.picture)
    }

    @Test
    fun aChangedConfigReachesTheSinkAgainSoTheDecoderRebuilds() = runTest {
        val rig = lanRig()
        rig.controller.connect()
        settle()

        val video = rig.videoConnections.single()
        video.deliver(Frame(MessageKind.VideoConfig, configPayload("display-1")))
        video.deliver(Frame(MessageKind.VideoFrame, framePayload(seed = 1, size = 10)))
        video.deliver(Frame(MessageKind.VideoConfig, configPayload("display-2")))
        video.deliver(Frame(MessageKind.VideoFrame, framePayload(seed = 2, size = 10)))
        settle()

        assertEquals(listOf("display-1", "display-2"), rig.sink.configs.map { it.sourceID })
        assertEquals(2, rig.sink.frames.size)
    }

    @Test
    fun aDroppedVideoConnectionIsReopenedDownTheLadder() = runTest {
        val rig = lanRig()
        rig.controller.connect()
        settle()
        rig.videoConnections.single().hostCloses()
        runCurrent()
        assertEquals(1, rig.videoConnections.size)

        advanceTimeBy(500)
        runCurrent()

        assertEquals(2, rig.videoConnections.size)
        assertEquals(MessageKind.ConnectionRole, rig.videoConnections.last().phoneFrames.first().kind)
        assertEquals(PictureState.Connecting, rig.controller.state.value.picture)
    }

    @Test
    fun aVideoConnectionThatNeverComesBackFailsThePictureNotTheSession() = runTest {
        val rig = lanRig()
        rig.controller.connect()
        settle()
        rig.videoReachable = false
        rig.videoConnections.single().hostCloses()

        advanceTimeBy(20_000)
        runCurrent()

        assertEquals(PictureState.Failed(PictureFailure.CouldNotOpen), rig.controller.state.value.picture)
        assertTrue(rig.controller.state.value.phase is SessionPhase.Ready)
    }

    @Test
    fun aRelayedSessionNeverOpensAVideoConnection() = runTest {
        val rig = ControllerRig(backgroundScope, testScheduler, ConnectTarget.Relay(ScriptedPairingHost.HOST_ID))
        rig.signalling.grantSession()
        rig.controller.connect()
        settle()

        assertTrue(rig.routes.none { it is ControlRoute.Video })
        assertTrue(rig.videoConnections.isEmpty())
    }

    @Test
    fun aPictureThatNeverArrivesStallsAndRetryReopensTheLane() = runTest {
        val rig = lanRig()
        rig.controller.connect()
        settle()
        assertEquals(PictureState.Connecting, rig.controller.state.value.picture)

        advanceTimeBy(7_000)
        runCurrent()
        assertEquals(PictureState.Stalled, rig.controller.state.value.picture)

        assertTrue(rig.controller.retryPicture())
        runCurrent()
        assertEquals(PictureState.Connecting, rig.controller.state.value.picture)
        assertTrue(rig.videoConnections.first().closed)
        assertEquals(2, rig.videoConnections.size)

        rig.videoConnections.last().deliver(Frame(MessageKind.VideoConfig, configPayload("display-1")))
        rig.videoConnections.last().deliver(Frame(MessageKind.VideoFrame, framePayload(seed = 1, size = 10)))
        settle()
        assertEquals(PictureState.Live, rig.controller.state.value.picture)
    }

    @Test
    fun retryAfterAFailureStartsTheLadderAgain() = runTest {
        val rig = lanRig()
        rig.controller.connect()
        settle()
        rig.videoReachable = false
        rig.videoConnections.single().hostCloses()
        advanceTimeBy(20_000)
        runCurrent()
        assertTrue(rig.controller.state.value.picture is PictureState.Failed)

        rig.videoReachable = true
        rig.controller.retryPicture()
        settle()

        assertEquals(2, rig.videoConnections.size)
        assertEquals(PictureState.Connecting, rig.controller.state.value.picture)
    }

    private fun TestScope.lanRig(): ControllerRig =
        ControllerRig(backgroundScope, testScheduler, ConnectTarget.Lan(ControllerRig.LAN_ADDRESS, ScriptedPairingHost.HOST_ID))

    private fun configPayload(sourceId: String): ByteArray = WireJson.encodeToString(
        VideoStreamConfig.serializer(),
        VideoStreamConfig(
            sourceID = sourceId,
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
}
