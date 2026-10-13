package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.relay.DirectPathState
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
}
