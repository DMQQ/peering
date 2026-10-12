package pl.dmq.peering.session.controller

import pl.dmq.peering.session.ports.VideoSink
import pl.dmq.peering.wire.EncodedVideoFrame
import pl.dmq.peering.wire.VideoStreamConfig

/** Passes everything to [inner] and keeps the last config, so the session can say what the stream is. */
internal class StreamRecord(private val inner: VideoSink) : VideoSink {
    @Volatile
    var config: VideoStreamConfig? = null
        private set

    override fun onConfig(config: VideoStreamConfig) {
        this.config = config
        inner.onConfig(config)
    }

    override fun onFrame(frame: EncodedVideoFrame) = inner.onFrame(frame)

    override val decoderFailed: Boolean get() = inner.decoderFailed

    override fun onStop() {
        config = null
        inner.onStop()
    }
}
