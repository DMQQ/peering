package pl.dmq.peering.session.ports

import pl.dmq.peering.wire.EncodedVideoFrame
import pl.dmq.peering.wire.VideoStreamConfig

/** Receives the decoded side of a video stream: the platform decoder sits behind this port. */
interface VideoSink {
    /** The stream's codec and size. Arrives before the first frame and again whenever they change. */
    fun onConfig(config: VideoStreamConfig)

    /** One encoded frame, in decode order. */
    fun onFrame(frame: EncodedVideoFrame)

    /** The stream has ended, so the decoder can be released. */
    fun onStop()
}
