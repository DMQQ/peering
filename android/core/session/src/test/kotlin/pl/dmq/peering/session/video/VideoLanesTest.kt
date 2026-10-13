package pl.dmq.peering.session.video

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.testing.FakeClock
import pl.dmq.peering.session.testing.FakeVideoSink
import pl.dmq.peering.wire.CONTROL_CHUNK_SIZE
import pl.dmq.peering.wire.EncodedVideoFrame
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.VideoChunkEncoder
import pl.dmq.peering.wire.VideoCodec
import pl.dmq.peering.wire.VideoDirection
import pl.dmq.peering.wire.VideoKeyGrant
import pl.dmq.peering.wire.VideoSealer
import pl.dmq.peering.wire.VideoStreamConfig
import pl.dmq.peering.wire.VideoTimestamp
import pl.dmq.peering.wire.VideoTransportKind
import pl.dmq.peering.wire.VideoTransportRequest
import pl.dmq.peering.wire.WireJson
import pl.dmq.peering.wire.toBase64

class VideoLanesTest {
    private val clock = FakeClock()
    private val sink = FakeVideoSink()
    private val relay = PeerAddress("relay.example", 4500)
    private val videoToken = ByteArray(16) { 7 }
    private val hostToken = ByteArray(16) { 9 }
    private val secret = ByteArray(32) { 3 }
    private val lanes = VideoLanes(sink, clock, relay, videoToken)
    private val hostSealer = VideoSealer(secret, VideoDirection.HostToClient, hostToken)

    @Test
    fun keyGrantOpensTheLaneAndBindsTheRelay() {
        val start = lanes.start()
        val request = start.filterIsInstance<LaneOutput.SendControl>().single()
        assertEquals(MessageKind.VideoKeyRequest, request.frame.kind)

        val outputs = lanes.onControlFrame(keyFrame(secret))

        val bind = outputs.filterIsInstance<LaneOutput.SendDatagram>().single()
        assertArrayEquals(videoToken, bind.bytes)
        assertEquals(relay, bind.destination)
    }

    @Test
    fun datagramPictureReachesTheSink() {
        openLane()

        for (datagram in hostDatagrams(MessageKind.VideoConfig, configPayload())) {
            assertTrue(lanes.onDatagram(datagram).authenticated)
        }
        for (datagram in hostDatagrams(MessageKind.VideoFrame, framePayload(ByteArray(64) { 1 }))) {
            assertTrue(lanes.onDatagram(datagram).authenticated)
        }

        assertEquals(1, sink.configs.size)
        assertEquals("source-1", sink.configs.single().sourceID)
        assertEquals(1, sink.frames.size)
        assertEquals(64, sink.frames.single().data.size)
    }

    @Test
    fun silentDatagramLaneRequestsControlFallback() {
        openLane()
        moveTo(1.0)
        lanes.onControlFrame(Frame(MessageKind.Pong, ByteArray(0)))

        val outputs = lanes.tick(3.0)

        val requests = transportRequests(outputs)
        assertEquals(listOf(VideoTransportKind.CONTROL), requests.map { it.transport })
        assertEquals(VideoTransportKind.CONTROL, lanes.delivery.transport)
        assertTrue(lanes.delivery.fellBack)
    }

    @Test
    fun controlChunksReassembleIntoOnePicture() {
        openLane()
        val frameData = ByteArray(40_000) { (it % 251).toByte() }
        val payload = framePayload(frameData)
        val chunks = VideoChunkEncoder.encode(MessageKind.VideoFrame, payload, 1, CONTROL_CHUNK_SIZE)
        assertTrue(chunks.size > 1)

        for (chunk in chunks) {
            lanes.onControlFrame(chunk)
        }

        assertEquals(1, sink.frames.size)
        assertArrayEquals(frameData, sink.frames.single().data)
    }

    @Test
    fun returnsToPrimaryAfterTwoPrimaryPictures() {
        openLane()
        moveTo(1.0)
        lanes.onControlFrame(Frame(MessageKind.Pong, ByteArray(0)))
        assertEquals(listOf(VideoTransportKind.CONTROL), transportRequests(lanes.tick(3.0)).map { it.transport })
        moveTo(3.5)
        lanes.onControlFrame(Frame(MessageKind.VideoConfig, configPayload()))

        moveTo(7.0)
        assertTrue(transportRequests(lanes.tick(7.0)).isEmpty())

        moveTo(7.4)
        deliverPrimaryPicture()
        moveTo(8.5)
        assertTrue(transportRequests(lanes.tick(8.5)).isEmpty())

        moveTo(8.6)
        deliverPrimaryPicture()
        moveTo(8.7)
        assertEquals(listOf(VideoTransportKind.PRIMARY), transportRequests(lanes.tick(8.7)).map { it.transport })
        assertEquals(VideoTransportKind.PRIMARY, lanes.delivery.transport)
        assertTrue(lanes.delivery.fellBack)
    }

    @Test
    fun wrongKeyCountsAFailureAndIsNotDelivered() {
        openLane()
        val otherSealer = VideoSealer(ByteArray(32) { 4 }, VideoDirection.HostToClient, hostToken)
        val forged = otherSealer.seal(MessageKind.VideoFrame, framePayload(ByteArray(8)))
            .map { it.copyOfRange(16, it.size) }

        val first = lanes.onDatagram(forged.single())
        val second = lanes.onDatagram(forged.single())

        assertFalse(first.authenticated)
        assertEquals(1, first.outputs.filterIsInstance<LaneOutput.Note>().size)
        assertFalse(second.authenticated)
        assertTrue(second.outputs.isEmpty())
        assertEquals(2, lanes.failedDatagrams)
        assertTrue(sink.frames.isEmpty())
    }

    private fun openLane() {
        lanes.start()
        lanes.onControlFrame(keyFrame(secret))
    }

    private fun moveTo(seconds: Double) {
        clock.advance(seconds - clock.monotonicSeconds())
    }

    private fun deliverPrimaryPicture() {
        for (datagram in hostDatagrams(MessageKind.VideoFrame, framePayload(ByteArray(8)))) {
            lanes.onDatagram(datagram)
        }
    }

    private fun hostDatagrams(kind: MessageKind, payload: ByteArray): List<ByteArray> =
        hostSealer.seal(kind, payload).map { it.copyOfRange(16, it.size) }

    private fun transportRequests(outputs: List<LaneOutput>): List<VideoTransportRequest> =
        outputs.filterIsInstance<LaneOutput.SendControl>()
            .map { it.frame }
            .filter { it.kind == MessageKind.VideoTransport }
            .map { WireJson.decodeFromString(VideoTransportRequest.serializer(), it.payload.decodeToString()) }

    private fun keyFrame(key: ByteArray): Frame = Frame(
        MessageKind.VideoKey,
        WireJson.encodeToString(VideoKeyGrant.serializer(), VideoKeyGrant(key.toBase64())).toByteArray(Charsets.UTF_8),
    )

    private fun configPayload(): ByteArray = WireJson.encodeToString(
        VideoStreamConfig.serializer(),
        VideoStreamConfig("source-1", VideoCodec.H264, 1920, 1080, listOf(byteArrayOf(1, 2).toBase64())),
    ).toByteArray(Charsets.UTF_8)

    private fun framePayload(data: ByteArray): ByteArray =
        EncodedVideoFrame(true, 1920, 1080, VideoTimestamp(1, 30), data).encode()
}
