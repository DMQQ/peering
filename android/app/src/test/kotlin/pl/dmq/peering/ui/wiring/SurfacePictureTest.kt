package pl.dmq.peering.ui.wiring

import android.graphics.SurfaceTexture
import android.view.Surface
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.ports.VideoSink
import pl.dmq.peering.wire.EncodedVideoFrame
import pl.dmq.peering.wire.VideoCodec
import pl.dmq.peering.wire.VideoStreamConfig
import pl.dmq.peering.wire.VideoTimestamp

class SurfacePictureTest {
    private class FakeDecoder(
        private val throwOnFrame: Boolean = false,
        private val throwOnStop: Boolean = false,
    ) : VideoSink {
        var stops = 0

        override fun onConfig(config: VideoStreamConfig) = Unit

        override fun onFrame(frame: EncodedVideoFrame) {
            if (throwOnFrame) throw IllegalStateException("decoder broke")
        }

        override fun onStop() {
            stops++
            if (throwOnStop) throw IllegalStateException("stop broke")
        }
    }

    private fun surface() = Surface(null as SurfaceTexture?)

    private fun frame() = EncodedVideoFrame(true, 100, 100, VideoTimestamp(0, 1), ByteArray(0))

    @Test
    fun aDecoderThatThrowsIsStoppedSoItsHardwareIsFreed() {
        val decoders = mutableListOf<FakeDecoder>()
        val picture = SurfacePicture { FakeDecoder(throwOnFrame = true).also(decoders::add) }
        picture.onSurfaceAvailable(surface())
        picture.onFrame(frame())
        assertEquals(1, decoders.single().stops)
        assertTrue(picture.decoderFailed)
    }

    @Test
    fun aDecoderWhoseStopAlsoThrowsDoesNotEscape() {
        val picture = SurfacePicture { FakeDecoder(throwOnFrame = true, throwOnStop = true) }
        picture.onSurfaceAvailable(surface())
        picture.onFrame(frame())
        assertTrue(picture.decoderFailed)
    }

    @Test
    fun aNewSurfaceStopsTheLiveDecoderBeforeReplacingIt() {
        val decoders = mutableListOf<FakeDecoder>()
        val picture = SurfacePicture { FakeDecoder().also(decoders::add) }
        picture.onSurfaceAvailable(surface())
        picture.onSurfaceAvailable(surface())
        assertEquals(2, decoders.size)
        assertEquals(1, decoders[0].stops)
        assertEquals(0, decoders[1].stops)
    }
}
