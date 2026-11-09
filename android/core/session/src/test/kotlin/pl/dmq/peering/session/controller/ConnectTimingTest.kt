@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.controller

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.flows.ScriptedPairingHost
import pl.dmq.peering.wire.EncodedVideoFrame
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.VideoCodec
import pl.dmq.peering.wire.VideoStreamConfig
import pl.dmq.peering.wire.VideoTimestamp
import pl.dmq.peering.wire.WireJson

class ConnectTimingTest {
    private val mark = Regex("""\+(\d+) ms (.+)""")

    private fun List<String>.marks(): List<Pair<Long, String>> =
        mapNotNull { mark.matchEntire(it) }.map { it.groupValues[1].toLong() to it.groupValues[2] }

    @Test
    fun aLocalConnectMarksEachStepFromTheRequestToTheFirstPicture() = runTest {
        val rig = lanRig()
        rig.controller.connect()
        settle()
        val video = rig.videoConnections.single()
        video.deliver(Frame(MessageKind.VideoConfig, configPayload()))
        video.deliver(Frame(MessageKind.VideoFrame, framePayload()))
        settle()

        assertEquals(
            listOf(
                "connect requested",
                "dial finished",
                "handshake done",
                "video lane dialling",
                "video lane open",
                "video lane role frame sent",
                "video lane first bytes",
                "video config received",
                "first video frame received",
                "first picture frame reached the decoder",
            ),
            rig.logged.marks().map { it.second },
        )
    }

    @Test
    fun marksReadAsTimeSinceTheConnectWasRequested() = runTest {
        val rig = lanRig()
        rig.controller.connect()
        settle()
        advanceTimeBy(2_500)
        rig.videoConnections.single().deliver(Frame(MessageKind.VideoConfig, configPayload()))
        settle()

        val marks = rig.logged.marks().associate { it.second to it.first }
        assertEquals(0L, marks["connect requested"])
        assertTrue(marks.getValue("video config received") >= 2_500)
    }

    @Test
    fun aStepThatHappensManyTimesIsMarkedOnce() = runTest {
        val rig = lanRig()
        rig.controller.connect()
        settle()
        val video = rig.videoConnections.single()
        repeat(3) {
            video.deliver(Frame(MessageKind.VideoConfig, configPayload()))
            video.deliver(Frame(MessageKind.VideoFrame, framePayload()))
        }
        settle()

        val names = rig.logged.marks().map { it.second }
        assertEquals(1, names.count { it == "video config received" })
        assertEquals(1, names.count { it == "first video frame received" })
        assertEquals(1, names.count { it == "first picture frame reached the decoder" })
    }

    @Test
    fun aPictureConnectionThatCannotBeOpenedIsMarkedWithWhyAndTheRetry() = runTest {
        val rig = lanRig()
        rig.videoReachable = false
        rig.controller.connect()
        settle()

        val names = rig.logged.marks().map { it.second }
        assertTrue(names.any { it.startsWith("video lane dial failed: ") })
        assertTrue(names.any { it.startsWith("video lane did not open, trying again in ") })
    }

    @Test
    fun theTimingPortHearsTheMarksAndNothingElse() = runTest {
        val rig = lanRig()
        rig.controller.connect()
        settle()

        assertTrue(rig.timed.isNotEmpty())
        assertTrue(rig.timed.all { mark.matches(it) })
        assertEquals(rig.logged.filter { mark.matches(it) }, rig.timed)
        assertFalse(rig.logged.all { mark.matches(it) })
    }

    @Test
    fun aSecondConnectStartsTheClockOver() = runTest {
        val rig = lanRig()
        rig.controller.connect()
        settle()
        rig.controller.disconnect()
        advanceTimeBy(10_000)
        rig.controller.connect()
        settle()

        val requested = rig.logged.marks().filter { it.second == "connect requested" }
        assertEquals(listOf(0L, 0L), requested.map { it.first })
    }

    private fun TestScope.lanRig(): ControllerRig =
        ControllerRig(backgroundScope, testScheduler, ConnectTarget.Lan(ControllerRig.LAN_ADDRESS, ScriptedPairingHost.HOST_ID))

    private suspend fun TestScope.settle() {
        advanceTimeBy(100)
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

    private fun framePayload(): ByteArray = EncodedVideoFrame(
        isKeyframe = true,
        pixelWidth = 1_920,
        pixelHeight = 1_080,
        presentationTime = VideoTimestamp(1, 90_000),
        data = ByteArray(10) { 1 },
    ).encode()
}
