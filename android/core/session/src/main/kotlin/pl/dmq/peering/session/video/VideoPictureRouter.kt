package pl.dmq.peering.session.video

import pl.dmq.peering.session.connection.HandshakeFrames
import pl.dmq.peering.session.ports.VideoSink
import pl.dmq.peering.wire.AudioStreamConfig
import pl.dmq.peering.wire.AudioWireException
import pl.dmq.peering.wire.EncodedAudioFrame
import pl.dmq.peering.wire.EncodedVideoFrame
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.VideoStreamConfig
import pl.dmq.peering.wire.VideoWireException

/**
 * Decodes a whole video config or frame and hands it to the sink. The computer's sound rides the same lanes and reaches
 * the sink too, but it is not a picture, so it never counts as one. Anything else, or anything malformed, is refused.
 */
internal class VideoPictureRouter(private val sink: VideoSink) {
    /** Returns true when a picture (a config or a frame) reached the sink. */
    fun deliver(frame: Frame): Boolean = when (frame.kind) {
        MessageKind.VideoConfig -> deliverConfig(frame)
        MessageKind.VideoFrame -> deliverFrame(frame)
        MessageKind.AudioConfig, MessageKind.AudioFrame -> {
            deliverSound(frame)
            false
        }
        else -> false
    }

    private fun deliverSound(frame: Frame) {
        if (frame.kind == MessageKind.AudioConfig) {
            HandshakeFrames.decode(frame, AudioStreamConfig.serializer())?.let(sink::onAudioConfig)
            return
        }
        val decoded = try {
            EncodedAudioFrame.decode(frame.payload)
        } catch (error: AudioWireException) {
            return
        }
        sink.onAudioFrame(decoded)
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
