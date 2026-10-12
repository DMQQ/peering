package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.relay.DirectPathState
import pl.dmq.peering.session.video.MosaicArrangement
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.CaptureSourceDescriptor
import pl.dmq.peering.wire.CaptureSourceKind
import pl.dmq.peering.wire.PixelSize
import pl.dmq.peering.wire.VideoCodec
import pl.dmq.peering.wire.VideoStreamConfig

class SessionFactsTest {
    private val peer = PeerAddress("203.0.113.7", 6000)

    @Test
    fun `a link that makes no attempt has no direct path row`() {
        assertNull(SessionFacts.directPathRow(null))
    }

    @Test
    fun `an open direct path has nothing to explain`() {
        assertNull(SessionFacts.directPathRow(DirectPathState.Open(peer)))
    }

    @Test
    fun `an attempt that has not opened says where it stands`() {
        assertEquals(DirectPathRow(DirectPathReport.NOT_TRIED, null), SessionFacts.directPathRow(DirectPathState.NotTried))
        assertEquals(DirectPathRow(DirectPathReport.NO_ADDRESS, null), SessionFacts.directPathRow(DirectPathState.NoAddress))
        assertEquals(DirectPathRow(DirectPathReport.PROBING, "203.0.113.7:6000"), SessionFacts.directPathRow(DirectPathState.Probing(peer)))
        assertEquals(DirectPathRow(DirectPathReport.UNUSABLE, "203.0.113.7:6000"), SessionFacts.directPathRow(DirectPathState.AddressUnusable(peer)))
    }

    @Test
    fun `the video row names the codec and the size`() {
        val hevc = VideoStreamConfig("d", VideoCodec.HEVC, 2560, 1440, listOf("AA"))
        val h264 = VideoStreamConfig("d", VideoCodec.H264, 1280, 720, listOf("AA"))

        assertEquals("HEVC 2560×1440", SessionFacts.of(null, hevc).video)
        assertEquals("H.264 1280×720", SessionFacts.of(null, h264).video)
        assertNull(SessionFacts.of(null, null).video)
    }

    @Test
    fun `editor rows know which controls can still act`() {
        val a = CaptureSource.Window(1)
        val b = CaptureSource.Window(2)
        val catalog = CaptureCatalog(
            windows = listOf(CaptureSourceDescriptor(id = "w1", kind = CaptureSourceKind.WINDOW, title = "Notes", source = a, pixelSize = PixelSize(800.0, 600.0))),
        )
        val tiles = editorTiles(MosaicArrangement.of(listOf(a, b)).resized(0, 2), catalog)

        assertEquals("Notes", tiles[0].title)
        assertNull(tiles[1].title)
        assertEquals(listOf(false, true), tiles.map { it.canMoveUp })
        assertEquals(listOf(true, false), tiles.map { it.canMoveDown })
        assertEquals(listOf(true, false), tiles.map { it.canShrink })
        assertEquals(listOf(false, true), tiles.map { it.canGrow })
    }
}
