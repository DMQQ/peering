package pl.dmq.peering.ui.wiring

import android.view.Surface
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import pl.dmq.peering.DebugLog
import pl.dmq.peering.feature.remote.SurfaceListener
import pl.dmq.peering.platform.video.CodecDecoder
import pl.dmq.peering.session.ports.VideoSink
import pl.dmq.peering.testing.TestBridge
import pl.dmq.peering.wire.EncodedVideoFrame
import pl.dmq.peering.wire.PixelSize
import pl.dmq.peering.wire.VideoStreamConfig

/**
 * The picture between a session and the screen. The session's frames reach a decoder only while the screen's surface
 * exists; a config that arrives before the surface waits for it. Every call comes on the main thread, where the session
 * scope and the screen both run, so no lock guards the decoder.
 */
internal class SurfacePicture(
    private val createDecoder: (Surface) -> VideoSink = ::CodecDecoder,
) : VideoSink, SurfaceListener {
    private val size = MutableStateFlow<PixelSize?>(null)
    private var surface: Surface? = null
    private var decoder: VideoSink? = null
    private var config: VideoStreamConfig? = null
    private val returns = SurfaceReturn()
    private var crashed = false

    /** The size of the stream the Mac is sending, or null before its first config. */
    val pixelSize: StateFlow<PixelSize?> = size.asStateFlow()

    override fun onConfig(config: VideoStreamConfig) {
        this.config = config
        size.value = PixelSize(config.pixelWidth.toDouble(), config.pixelHeight.toDouble())
        // A reconnect on the same screen has released the decoder but kept the surface, so the next config rebuilds it.
        val live = decoder ?: surface?.let(createDecoder)?.also { decoder = it }
        guarded(live) { it.onConfig(config) }
    }

    override fun onFrame(frame: EncodedVideoFrame) {
        TestBridge.frameArrived()
        guarded(decoder) { it.onFrame(frame) }
    }

    override fun onStop() {
        guarded(decoder) { it.onStop() }
        decoder = null
        config = null
        crashed = false
    }

    override val decoderFailed: Boolean get() = crashed || decoder?.decoderFailed == true

    /** A decoder that throws past its own recovery is dropped, so the picture reads as failed and the session lives. */
    private fun guarded(target: VideoSink?, call: (VideoSink) -> Unit) {
        target ?: return
        try {
            call(target)
        } catch (error: RuntimeException) {
            DebugLog.w(TAG, { "the decoder threw past its recovery" }, error)
            crashed = true
            if (decoder === target) decoder = null
            try {
                target.onStop()
            } catch (stopError: RuntimeException) {
                DebugLog.w(TAG, { "releasing the crashed decoder failed" }, stopError)
            }
        }
    }

    /** True when the last surface replaced one that was showing the stream, so the stream needs a fresh keyframe. */
    var surfaceReturnedWithoutKeyframe = false
        private set

    override fun onSurfaceAvailable(surface: Surface) {
        surfaceReturnedWithoutKeyframe = returns.available()
        guarded(decoder) { it.onStop() }
        decoder = null
        this.surface = surface
        val created = createDecoder(surface)
        decoder = created
        crashed = false
        config?.let { guarded(created) { decoder -> decoder.onConfig(it) } }
    }

    override fun onSurfaceSizeChanged(width: Int, height: Int) = Unit

    override fun onSurfaceGone() {
        returns.gone(hadPicture = decoder != null && config != null)
        guarded(decoder) { it.onStop() }
        decoder = null
        surface = null
    }
}

private const val TAG = "PeeringPicture"
