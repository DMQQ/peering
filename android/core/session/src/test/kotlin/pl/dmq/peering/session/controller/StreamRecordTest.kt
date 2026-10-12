package pl.dmq.peering.session.controller

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.session.ports.VideoSink
import pl.dmq.peering.wire.EncodedVideoFrame
import pl.dmq.peering.wire.VideoCodec
import pl.dmq.peering.wire.VideoStreamConfig

class StreamRecordTest {
    private val passed = mutableListOf<String>()
    private val inner = object : VideoSink {
        override fun onConfig(config: VideoStreamConfig) { passed += "config" }
        override fun onFrame(frame: EncodedVideoFrame) { passed += "frame" }
        override fun onStop() { passed += "stop" }
    }
    private val config = VideoStreamConfig("display:1", VideoCodec.HEVC, 1920, 1080, listOf("AA"))

    @Test
    fun `it keeps the last config and still passes it on`() {
        val record = StreamRecord(inner)
        assertNull(record.config)

        record.onConfig(config)

        assertEquals(config, record.config)
        assertEquals(listOf("config"), passed)
    }

    @Test
    fun `a stopped stream has no config`() {
        val record = StreamRecord(inner)
        record.onConfig(config)

        record.onStop()

        assertNull(record.config)
        assertEquals(listOf("config", "stop"), passed)
    }
}
