package pl.dmq.peering.ui.wiring

import android.view.Surface
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import pl.dmq.peering.feature.remote.SurfaceListener
import pl.dmq.peering.platform.video.CodecDecoder
import pl.dmq.peering.session.ports.VideoSink
import pl.dmq.peering.wire.EncodedVideoFrame
import pl.dmq.peering.wire.PixelSize
import pl.dmq.peering.wire.VideoStreamConfig

/**
 * The picture between a session and the screen. The session's frames reach a decoder only while the screen's surface
 * exists; a config that arrives before the surface waits for it. Every call comes on the main thread, where the session
 * scope and the screen both run, so no lock guards the decoder.
 */
internal class SurfacePicture : VideoSink, SurfaceListener {
    private val size = MutableStateFlow<PixelSize?>(null)
    private var surface: Surface? = null
    private var decoder: CodecDecoder? = null
    private var config: VideoStreamConfig? = null

    /** The size of the stream the Mac is sending, or null before its first config. */
    val pixelSize: StateFlow<PixelSize?> = size.asStateFlow()

    override fun onConfig(config: VideoStreamConfig) {
        this.config = config
        size.value = PixelSize(config.pixelWidth.toDouble(), config.pixelHeight.toDouble())
        // A reconnect on the same screen has released the decoder but kept the surface, so the next config rebuilds it.
        val live = decoder ?: surface?.let(::CodecDecoder)?.also { decoder = it }
        live?.onConfig(config)
    }

    override fun onFrame(frame: EncodedVideoFrame) {
        decoder?.onFrame(frame)
    }

    override fun onStop() {
        decoder?.onStop()
        decoder = null
        config = null
    }

    override fun onSurfaceAvailable(surface: Surface) {
        this.surface = surface
        val created = CodecDecoder(surface)
        decoder = created
        config?.let(created::onConfig)
    }

    override fun onSurfaceSizeChanged(width: Int, height: Int) = Unit

    override fun onSurfaceGone() {
        decoder?.onStop()
        decoder = null
        surface = null
    }
}
