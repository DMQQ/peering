package pl.dmq.peering.session.ports

import pl.dmq.peering.wire.AudioStreamConfig
import pl.dmq.peering.wire.EncodedAudioFrame
import pl.dmq.peering.wire.EncodedVideoFrame
import pl.dmq.peering.wire.VideoStreamConfig

/** Receives the decoded side of a video stream: the platform decoder sits behind this port. */
interface VideoSink {
    /** The stream's codec and size. Arrives before the first frame and again whenever they change. */
    fun onConfig(config: VideoStreamConfig)

    /** One encoded frame, in decode order. */
    fun onFrame(frame: EncodedVideoFrame)

    /** The computer's sound, announced before its first frame and again when it changes. A sink with no speaker ignores it. */
    fun onAudioConfig(config: AudioStreamConfig) = Unit

    /** One block of the computer's sound. */
    fun onAudioFrame(frame: EncodedAudioFrame) = Unit

    /** The stream has ended, so the decoder can be released. */
    fun onStop()

    /** True once the decoder gave up on the stream, until a config it can start arrives. */
    val decoderFailed: Boolean get() = false
}
