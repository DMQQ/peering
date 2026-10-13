package pl.dmq.peering.session.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.testing.FakeVideoSink
import pl.dmq.peering.wire.AudioCodec
import pl.dmq.peering.wire.AudioStreamConfig
import pl.dmq.peering.wire.EncodedAudioFrame
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.VideoTimestamp
import pl.dmq.peering.wire.WireJson

class SoundRoutingTest {
    private val sink = FakeVideoSink()
    private val router = VideoPictureRouter(sink)

    private val config = AudioStreamConfig(AudioCodec.PCM_FLOAT32, 48_000.0, 2)

    private fun configFrame(json: String = WireJson.encodeToString(AudioStreamConfig.serializer(), config)) =
        Frame(MessageKind.AudioConfig, json.encodeToByteArray())

    @Test
    fun anAudioConfigReachesTheSinkButIsNotAPicture() {
        assertFalse(router.deliver(configFrame()))
        assertEquals(listOf(config), sink.audioConfigs)
    }

    @Test
    fun anAudioFrameReachesTheSinkButIsNotAPicture() {
        val frame = EncodedAudioFrame(1, 2, VideoTimestamp(5, 48_000), ByteArray(8))
        assertFalse(router.deliver(Frame(MessageKind.AudioFrame, frame.encode())))
        assertEquals(1, sink.audioFrames.size)
        assertEquals(5L, sink.audioFrames.single().presentationTime.value)
    }

    @Test
    fun malformedSoundIsDroppedWithoutReachingTheSink() {
        router.deliver(configFrame("{\"codec\":\"opus\"}"))
        router.deliver(Frame(MessageKind.AudioFrame, ByteArray(7)))
        router.deliver(Frame(MessageKind.AudioFrame, EncodedAudioFrame(2, 2, VideoTimestamp(0, 1), ByteArray(8)).encode()))
        assertTrue(sink.audioConfigs.isEmpty())
        assertTrue(sink.audioFrames.isEmpty())
    }
}
