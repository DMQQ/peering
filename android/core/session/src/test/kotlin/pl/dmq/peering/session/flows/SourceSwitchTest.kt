package pl.dmq.peering.session.flows

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.session.ports.VideoSink
import pl.dmq.peering.session.testing.FakeVideoSink
import pl.dmq.peering.session.video.SourceSelection
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.CaptureSourceDescriptor
import pl.dmq.peering.wire.CaptureSourceKind
import pl.dmq.peering.wire.EncodedVideoFrame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.NormalizedPoint
import pl.dmq.peering.wire.PixelSize
import pl.dmq.peering.wire.SetCaptureSource
import pl.dmq.peering.wire.VideoCodec
import pl.dmq.peering.wire.VideoStreamConfig
import pl.dmq.peering.wire.WireJson

class SourceSwitchTest {
    private val main = display(id = 1, width = 2_880.0, height = 1_800.0)
    private val external = display(id = 2, width = 1_920.0, height = 1_080.0)
    private val sameSizeAsMain = display(id = 3, width = 2_880.0, height = 1_800.0)
    private val catalog = CaptureCatalog(displays = listOf(main, external, sameSizeAsMain))

    @Test
    fun aSwitchToTheSamePixelSizeOwesNoConfig() = runTest {
        val selection = SourceSelection()
        val rig = RelayRig(backgroundScope, testScheduler) { Accounting(it, selection) }
        rig.connect()
        selection.onCatalog(catalog)
        selection.choose(main.source)
        rig.sendDatagram(MessageKind.VideoConfig, configPayload(main.pixelSize))
        rig.settle()

        selection.choose(sameSizeAsMain.source)

        assertEquals(0, selection.configUpdatesOwed)
        assertEquals(1, rig.sink.configs.size)
    }

    @Test
    fun aSwitchToAnotherPixelSizeOwesOneConfigAndTheLanePaysItBack() = runTest {
        val selection = SourceSelection()
        val rig = RelayRig(backgroundScope, testScheduler) { Accounting(it, selection) }
        rig.connect()
        selection.onCatalog(catalog)
        selection.choose(main.source)
        rig.sendDatagram(MessageKind.VideoConfig, configPayload(main.pixelSize))
        rig.settle()

        selection.choose(external.source)
        assertEquals(1, selection.configUpdatesOwed)

        rig.sendDatagram(MessageKind.VideoConfig, configPayload(external.pixelSize))
        rig.settle()
        assertEquals(0, selection.configUpdatesOwed)
        assertEquals(1_920, rig.sink.configs.last().pixelWidth)
    }

    @Test
    fun theInputTransformFollowsTheActiveDisplay() = runTest {
        val selection = SourceSelection()
        val rig = RelayRig(backgroundScope, testScheduler) { Accounting(it, selection) }
        rig.connect()
        selection.onCatalog(catalog)
        selection.choose(main.source)
        assertEquals(main.pixelSize, selection.inputTransform(viewWidth = 960.0, viewHeight = 960.0)?.pixelSize)

        selection.choose(external.source)
        rig.sendDatagram(MessageKind.VideoConfig, configPayload(external.pixelSize))
        rig.settle()

        val transform = selection.inputTransform(viewWidth = 960.0, viewHeight = 960.0)!!
        assertEquals(external.pixelSize, transform.pixelSize)
        assertEquals(NormalizedPoint(1.0, 1.0), transform.normalizedPoint(960.0, 750.0))
    }

    @Test
    fun theResumeSourceIsRememberedForTheNextHello() {
        val selection = SourceSelection()
        selection.onCatalog(catalog)

        selection.choose(external.source)

        assertEquals(external.source.toJson(), selection.resumeSourceJson())
        val nextSession = SourceSelection(restored = selection.resumeSource)
        assertEquals(external.source.toJson(), nextSession.resumeSourceJson())
    }

    @Test
    fun aVanishedDisplayFallsBackToTheFirstDisplayAndTheMacIsTold() {
        val selection = SourceSelection()
        selection.onCatalog(catalog)
        selection.choose(external.source)

        val command = selection.onCatalog(CaptureCatalog(displays = listOf(main, sameSizeAsMain)))

        assertEquals(SetCaptureSource(main.source), command)
        assertEquals(main.source, selection.chosen)
        assertEquals(main.source, selection.resumeSource)
    }

    /** The phone's glue: each config the lane delivers pays one owed update back to the selection. */
    private class Accounting(private val recorded: FakeVideoSink, private val selection: SourceSelection) : VideoSink {
        override fun onConfig(config: VideoStreamConfig) {
            recorded.onConfig(config)
            selection.onVideoConfig()
        }

        override fun onFrame(frame: EncodedVideoFrame) = recorded.onFrame(frame)

        override fun onStop() = recorded.onStop()
    }

    private fun configPayload(size: PixelSize): ByteArray = WireJson.encodeToString(
        VideoStreamConfig.serializer(),
        VideoStreamConfig(
            sourceID = "display",
            codec = VideoCodec.H264,
            pixelWidth = size.width.toInt(),
            pixelHeight = size.height.toInt(),
            parameterSets = listOf("Z0IAHo="),
        ),
    ).toByteArray(Charsets.UTF_8)

    private fun display(id: Long, width: Double, height: Double) = CaptureSourceDescriptor(
        id = "display:$id",
        kind = CaptureSourceKind.DISPLAY,
        title = "Display $id",
        source = CaptureSource.Display(id),
        pixelSize = PixelSize(width, height),
    )
}
