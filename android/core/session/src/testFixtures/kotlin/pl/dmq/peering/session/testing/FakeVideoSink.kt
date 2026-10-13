package pl.dmq.peering.session.testing

import pl.dmq.peering.session.ports.VideoSink
import pl.dmq.peering.wire.AudioStreamConfig
import pl.dmq.peering.wire.EncodedAudioFrame
import pl.dmq.peering.wire.EncodedVideoFrame
import pl.dmq.peering.wire.VideoStreamConfig

/** Keeps every callback in the order it arrived. */
class FakeVideoSink : VideoSink {
    val configs = mutableListOf<VideoStreamConfig>()
    val frames = mutableListOf<EncodedVideoFrame>()

    val audioConfigs = mutableListOf<AudioStreamConfig>()
    val audioFrames = mutableListOf<EncodedAudioFrame>()

    override fun onAudioConfig(config: AudioStreamConfig) {
        audioConfigs += config
    }

    override fun onAudioFrame(frame: EncodedAudioFrame) {
        audioFrames += frame
    }

    var stops = 0
        private set

    override var decoderFailed = false

    override fun onConfig(config: VideoStreamConfig) {
        configs += config
    }

    override fun onFrame(frame: EncodedVideoFrame) {
        frames += frame
    }

    override fun onStop() {
        stops += 1
    }
}
