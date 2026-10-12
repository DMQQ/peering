package pl.dmq.peering.session.controller

import pl.dmq.peering.session.ports.VideoSink
import pl.dmq.peering.wire.EncodedVideoFrame
import pl.dmq.peering.wire.VideoStreamConfig

/** Passes everything to [inner] and reports the first frame of a stream, which is what makes the picture live. */
internal class PictureSink(private val inner: VideoSink, private val onPicture: () -> Unit) : VideoSink {
    override fun onConfig(config: VideoStreamConfig) {
        inner.onConfig(config)
    }

    override fun onFrame(frame: EncodedVideoFrame) {
        inner.onFrame(frame)
        onPicture()
    }

    override fun onStop() {
        inner.onStop()
    }
}
