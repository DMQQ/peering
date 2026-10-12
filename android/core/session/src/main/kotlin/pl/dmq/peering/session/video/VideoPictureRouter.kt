package pl.dmq.peering.session.video

import pl.dmq.peering.session.connection.HandshakeFrames
import pl.dmq.peering.session.ports.VideoSink
import pl.dmq.peering.wire.EncodedVideoFrame
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.VideoStreamConfig
import pl.dmq.peering.wire.VideoWireException

/** Decodes a whole video config or frame and hands it to the sink. Anything else, or anything malformed, is refused. */
internal class VideoPictureRouter(private val sink: VideoSink) {
    /** Returns true when a picture (a config or a frame) reached the sink. */
    fun deliver(frame: Frame): Boolean = when (frame.kind) {
        MessageKind.VideoConfig -> deliverConfig(frame)
        MessageKind.VideoFrame -> deliverFrame(frame)
        else -> false
    }

    private fun deliverConfig(frame: Frame): Boolean {
        val config = HandshakeFrames.decode(frame, VideoStreamConfig.serializer()) ?: return false
        if (!config.isWithinLimits) return false
        sink.onConfig(config)
        return true
    }

    private fun deliverFrame(frame: Frame): Boolean {
        val decoded = try {
            EncodedVideoFrame.decode(frame.payload)
        } catch (error: VideoWireException) {
            return false
        }
        sink.onFrame(decoded)
        return true
    }
}
