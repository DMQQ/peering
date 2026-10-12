package pl.dmq.peering.session.clipboard

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.connection.HandshakeFrames
import pl.dmq.peering.session.connection.ClientConfig
import pl.dmq.peering.wire.ClientHello
import pl.dmq.peering.wire.MAX_CLIPBOARD_IMAGE_BYTES
import pl.dmq.peering.wire.MAX_CLIPBOARD_REASSEMBLED_BYTES
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.PushClipboardImage
import pl.dmq.peering.wire.RemoteCommand
import pl.dmq.peering.wire.ServerHello
import pl.dmq.peering.wire.VideoChunkReassembler
import pl.dmq.peering.wire.WireJson
import pl.dmq.peering.wire.fromBase64

class ClipboardImageFramesTest {
    private fun host(images: Boolean?) = ServerHello(
        serverID = "s",
        hostName = "h",
        protocolVersion = 20,
        alreadyPaired = true,
        supportsClipboardImages = images,
    )

    private fun ready(png: ByteArray) =
        (ClipboardImageFrames.build(host(true), png, 7) as ClipboardImageFrames.Ready).frames

    @Test
    fun aHostThatDidNotDeclareImagesIsSentNone() {
        assertEquals(ClipboardPush.Unsupported, (ClipboardImageFrames.build(host(null), ByteArray(4), 1) as ClipboardImageFrames.Refused).reason)
        assertEquals(ClipboardPush.Unsupported, (ClipboardImageFrames.build(host(false), ByteArray(4), 1) as ClipboardImageFrames.Refused).reason)
    }

    @Test
    fun aPictureOverTheCapIsRefusedWithItsSize() {
        val size = MAX_CLIPBOARD_IMAGE_BYTES + 1
        val refused = ClipboardImageFrames.build(host(true), ByteArray(size), 1) as ClipboardImageFrames.Refused

        assertEquals(ClipboardPush.TooLarge(size), refused.reason)
    }

    @Test
    fun aSmallPictureIsOneCommandFrame() {
        val frames = ready(byteArrayOf(1, 2, 3))

        assertEquals(1, frames.size)
        assertEquals(MessageKind.Command, frames.single().kind)
    }

    @Test
    fun aLargePictureIsChunkedAndReassemblesToTheSameBytes() {
        val png = ByteArray(200_000) { (it % 251).toByte() }
        val frames = ready(png)

        assertTrue(frames.size > 1)
        assertTrue(frames.all { it.kind == MessageKind.VideoChunk })
        val reassembler = VideoChunkReassembler(MAX_CLIPBOARD_REASSEMBLED_BYTES)
        val whole = frames.mapNotNull(reassembler::ingest).single()
        assertEquals(MessageKind.Command, whole.kind)
        val command: RemoteCommand = RemoteCommand.parse(whole.payload.decodeToString())
        assertArrayEquals(png, (command as PushClipboardImage).png.fromBase64())
    }

    @Test
    fun theHelloDeclaresClipboardImagesNowThatTheyAreSupported() {
        val config = ClientConfig(clientId = "c", clientName = "n", dialledHostId = null, serverKey = ByteArray(0))
        val frame = HandshakeFrames.clientHello(config, knowsHost = true)
        val hello = WireJson.decodeFromString(ClientHello.serializer(), frame.payload.decodeToString())

        assertEquals(true, hello.supportsClipboardImages)
    }
}
