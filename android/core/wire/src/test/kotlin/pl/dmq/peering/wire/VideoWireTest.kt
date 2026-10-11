package pl.dmq.peering.wire

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.intOrNull
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class VideoWireTest {
    private fun vector(name: String): JsonObject = VectorFiles.load("wire.json").jsonObject.getValue(name).jsonObject

    private fun JsonObject.hex(key: String): ByteArray = getValue(key).jsonPrimitive.content.hexToBytes()

    private fun config(parameterSets: List<String> = listOf(base64("sps"))) = VideoStreamConfig(
        sourceID = "display-1",
        codec = VideoCodec.H264,
        pixelWidth = 1920,
        pixelHeight = 1080,
        parameterSets = parameterSets,
    )

    private fun base64(text: String): String = Base64.getEncoder().encodeToString(text.toByteArray())

    @Test
    fun theSharedVideoFrameVectorDecodesToItsFields() {
        val vector = vector("videoFrame")
        val frame = EncodedVideoFrame.decode(vector.hex("bytes"))

        assertEquals(vector.getValue("keyframe").jsonPrimitive.content.toBoolean(), frame.isKeyframe)
        assertEquals(1920, frame.pixelWidth)
        assertEquals(1080, frame.pixelHeight)
        assertEquals(VideoTimestamp(90_000, 90_000), frame.presentationTime)
        assertArrayEquals(vector.hex("data"), frame.data)
    }

    @Test
    fun theSharedVideoFrameVectorEncodesToTheSameBytes() {
        val vector = vector("videoFrame")
        val frame = EncodedVideoFrame.decode(vector.hex("bytes"))

        assertArrayEquals(vector.hex("bytes"), frame.encode())
    }

    @Test
    fun theSharedVideoErrorVectorsThrowTheirNamedErrors() {
        val cases = VectorFiles.load("wire.json").jsonObject.getValue("videoFrameErrors").jsonArray
        val byName = cases.associateBy { it.jsonObject.getValue("name").jsonPrimitive.content }

        val mismatch = byName.getValue("length mismatch").jsonObject
        assertThrows(VideoWireException.LengthMismatch::class.java) {
            EncodedVideoFrame.decode(mismatch.hex("bytes"))
        }
        val truncated = byName.getValue("truncated header").jsonObject
        assertThrows(VideoWireException.TruncatedHeader::class.java) {
            EncodedVideoFrame.decode(truncated.hex("bytes"))
        }
    }

    @Test
    fun aDeclaredLengthOfFourGigabytesIsAMismatchNotAnOverflow() {
        val error = assertThrows(VideoWireException.LengthMismatch::class.java) {
            EncodedVideoFrame.decode(videoFrame(declaredLength = 0xFFFF_FFFFL, body = ByteArray(0)))
        }
        assertEquals(0xFFFF_FFFFL, error.declared)
    }

    @Test
    fun aWidthAboveSignedIntRangeIsRejected() {
        val bytes = videoFrame(width = 0xFFFF_FFFFL, declaredLength = 0, body = ByteArray(0))

        assertThrows(VideoWireException.DimensionOutOfRange::class.java) {
            EncodedVideoFrame.decode(bytes)
        }
    }

    @Test
    fun theSharedAudioFrameVectorDecodesAndEncodesBack() {
        val vector = vector("audioFrame")
        val bytes = vector.hex("bytes")
        val frame = EncodedAudioFrame.decode(bytes)

        assertEquals(2, frame.sampleCount)
        assertEquals(2, frame.channelCount)
        assertEquals(VideoTimestamp(44_100, 44_100), frame.presentationTime)
        assertEquals(16, frame.samples.size)
        assertArrayEquals(bytes, frame.encode())
    }

    @Test
    fun audioFramesRejectInvalidCountsAndLengths() {
        assertThrows(AudioWireException.TruncatedHeader::class.java) {
            EncodedAudioFrame.decode(ByteArray(19))
        }
        assertThrows(AudioWireException.InvalidSampleCount::class.java) {
            EncodedAudioFrame.decode(audioHeader(sampleCount = 0, channelCount = 2, body = ByteArray(0)))
        }
        assertThrows(AudioWireException.InvalidChannelCount::class.java) {
            EncodedAudioFrame.decode(audioHeader(sampleCount = 1, channelCount = 0, body = ByteArray(0)))
        }
        assertThrows(AudioWireException.InvalidChannelCount::class.java) {
            EncodedAudioFrame.decode(audioHeader(sampleCount = 1, channelCount = 33, body = ByteArray(132)))
        }
        assertThrows(AudioWireException.LengthMismatch::class.java) {
            EncodedAudioFrame.decode(audioHeader(sampleCount = 2, channelCount = 2, body = ByteArray(15)))
        }
    }

    @Test
    fun anAudioFrameWhoseSampleByteCountOverflowsIsAMismatchNotAnOverflow() {
        val bytes = audioHeader(sampleCount = 0xFFFF_FFFFL, channelCount = 32, body = ByteArray(0))

        val error = assertThrows(AudioWireException.LengthMismatch::class.java) {
            EncodedAudioFrame.decode(bytes)
        }
        assertEquals(0xFFFF_FFFFL * 32 * 4, error.declared)
    }

    @Test
    fun theVideoTimestampReadsZeroForAZeroTimescale() {
        assertEquals(1.0, VideoTimestamp(90_000, 90_000).seconds, 0.0)
        assertEquals(0.0, VideoTimestamp(90_000, 0).seconds, 0.0)
    }

    @Test
    fun aConfigWithNoParameterSetsIsNotAnUpdate() {
        assertNull(VideoStreamConfig.updated(previous = null, candidate = config(parameterSets = emptyList())))
    }

    @Test
    fun anUnchangedConfigIsNotAnUpdate() {
        val current = config()

        assertNull(VideoStreamConfig.updated(previous = current, candidate = config()))
    }

    @Test
    fun aChangedOrFirstConfigIsAnUpdate() {
        val first = config()
        assertEquals(first, VideoStreamConfig.updated(previous = null, candidate = first))

        val resized = first.copy(pixelWidth = 2560)
        assertEquals(resized, VideoStreamConfig.updated(previous = first, candidate = resized))
    }

    @Test
    fun parameterSetsDecodeFromBase64() {
        val sets = config(listOf(base64("sps"), base64("pps"))).parameterSetBytes()

        assertEquals(2, sets.size)
        assertArrayEquals("sps".toByteArray(), sets[0])
        assertArrayEquals("pps".toByteArray(), sets[1])
    }

    @Test
    fun theConfigSerialisesWithWireFieldNames() {
        val json = Json.encodeToString(VideoStreamConfig.serializer(), config())
        val fields = Json.parseToJsonElement(json).jsonObject

        assertEquals("display-1", fields.getValue("sourceID").jsonPrimitive.content)
        assertEquals("h264", fields.getValue("codec").jsonPrimitive.content)
        assertEquals(1920, fields.getValue("pixelWidth").jsonPrimitive.intOrNull)
        assertEquals(listOf(base64("sps")), fields.getValue("parameterSets").jsonArray.map { it.jsonPrimitive.content })
    }

    private fun videoFrame(
        width: Long = 1920,
        declaredLength: Long,
        body: ByteArray,
    ): ByteArray = ByteBuffer.allocate(EncodedVideoFrame.HEADER_SIZE + body.size).order(ByteOrder.BIG_ENDIAN).apply {
        put(1)
        putInt(width.toInt())
        putInt(1080)
        putLong(0)
        putInt(1)
        putInt(declaredLength.toInt())
        put(body)
    }.array()

    private fun audioHeader(sampleCount: Long, channelCount: Long, body: ByteArray): ByteArray =
        ByteBuffer.allocate(EncodedAudioFrame.HEADER_SIZE + body.size).order(ByteOrder.BIG_ENDIAN).apply {
            putInt(sampleCount.toInt())
            putInt(channelCount.toInt())
            putLong(0)
            putInt(1)
            put(body)
        }.array()
}
