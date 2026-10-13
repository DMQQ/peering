package pl.dmq.peering.wire

import java.nio.ByteBuffer
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoSealingTest {
    private val crypto: JsonObject = VectorFiles.load("crypto.json").jsonObject

    private fun vectorSecret(): ByteArray = (0 until 32).map { ((it * 31 + 7) and 0xFF).toByte() }.toByteArray()

    private fun vectorToken(): ByteArray = (0 until 16).map { ((it * 7 + 1) and 0xFF).toByte() }.toByteArray()

    private fun pingPayload(): ByteArray = """{"sequence":1}""".toByteArray()

    private fun relayed(datagram: ByteArray): ByteArray = datagram.copyOfRange(VIDEO_TOKEN_SIZE, datagram.size)

    private fun picture(size: Int): ByteArray = ByteArray(size) { (it % 253).toByte() }

    @Test
    fun derivedKeysMatchTheVector() {
        val hkdf = crypto.getValue("hkdf").jsonObject
        val secret = hkdf.getValue("secret").jsonPrimitive.content.hexToBytes()
        assertEquals(
            hkdf.getValue("clientToHostKey").jsonPrimitive.content,
            deriveVideoKey(secret, VideoDirection.ClientToHost).toHex(),
        )
        assertEquals(
            hkdf.getValue("hostToClientKey").jsonPrimitive.content,
            deriveVideoKey(secret, VideoDirection.HostToClient).toHex(),
        )
    }

    @Test
    fun aSecretOfTheWrongLengthIsRejected() {
        assertThrows(SealException.BadSecret::class.java) {
            deriveVideoKey(ByteArray(5), VideoDirection.HostToClient)
        }
    }

    @Test
    fun aSealedPingMatchesTheVectorByteForByte() {
        val sealed = crypto.getValue("sealedDatagram").jsonObject
        val datagrams = VideoSealer(vectorSecret(), VideoDirection.HostToClient, vectorToken())
            .seal(MessageKind.Ping, pingPayload())
        assertEquals(1, datagrams.size)
        assertEquals(sealed.getValue("asSent").jsonPrimitive.content, datagrams[0].toHex())
    }

    @Test
    fun theBindDatagramIsTheBareToken() {
        val sealer = VideoSealer(vectorSecret(), VideoDirection.ClientToHost, vectorToken())
        assertArrayEquals(vectorToken(), sealer.bindDatagram())
    }

    @Test
    fun aSealedPingOpensToTheSameFrame() {
        val datagram = VideoSealer(vectorSecret(), VideoDirection.HostToClient, vectorToken())
            .seal(MessageKind.Ping, pingPayload()).single()
        val opener = VideoOpener(vectorSecret(), VideoDirection.HostToClient)
        assertEquals(Frame(MessageKind.Ping, pingPayload()), opener.open(relayed(datagram)))
    }

    @Test
    fun theCounterStartsAtOneAndCountsEachDatagram() {
        val sealer = VideoSealer(vectorSecret(), VideoDirection.HostToClient, vectorToken())
        val first = sealer.seal(MessageKind.Ping, pingPayload()).single()
        val second = sealer.seal(MessageKind.Ping, pingPayload()).single()
        assertEquals(1L, ByteBuffer.wrap(first, VIDEO_TOKEN_SIZE, 8).long)
        assertEquals(2L, ByteBuffer.wrap(second, VIDEO_TOKEN_SIZE, 8).long)
    }

    @Test
    fun aLargeMessageCrossesInChunksAndOpensWhenComplete() {
        val sealer = VideoSealer(vectorSecret(), VideoDirection.HostToClient, vectorToken())
        val opener = VideoOpener(vectorSecret(), VideoDirection.HostToClient)
        val datagrams = sealer.seal(MessageKind.VideoFrame, picture(5000))
        assertTrue(datagrams.size > 4)
        assertTrue(datagrams.all { it.size <= 1100 })
        val opened = datagrams.map { opener.open(relayed(it)) }
        assertTrue(opened.dropLast(1).all { it == null })
        assertEquals(Frame(MessageKind.VideoFrame, picture(5000)), opened.last())
    }

    @Test
    fun aReplayedDatagramIsDropped() {
        val datagram = VideoSealer(vectorSecret(), VideoDirection.HostToClient, vectorToken())
            .seal(MessageKind.Ping, pingPayload()).single()
        val opener = VideoOpener(vectorSecret(), VideoDirection.HostToClient)
        assertNotNull(opener.open(relayed(datagram)))
        assertNull(opener.open(relayed(datagram)))
    }

    @Test
    fun aForgedDatagramDoesNotAdvanceTheWindow() {
        val sealer = VideoSealer(vectorSecret(), VideoDirection.HostToClient, vectorToken())
        val genuine = relayed(sealer.seal(MessageKind.Ping, pingPayload()).single())
        val forged = genuine.copyOf()
        ByteBuffer.wrap(forged).putLong(0, Long.MAX_VALUE)
        val opener = VideoOpener(vectorSecret(), VideoDirection.HostToClient)
        assertThrows(SealException.AuthenticationFailed::class.java) { opener.open(forged) }
        assertEquals(Frame(MessageKind.Ping, pingPayload()), opener.open(genuine))
    }

    @Test
    fun aTamperedDatagramIsRejected() {
        val datagram = relayed(VideoSealer(vectorSecret(), VideoDirection.HostToClient, vectorToken())
            .seal(MessageKind.Ping, pingPayload()).single())
        datagram[datagram.size - 1] = (datagram.last().toInt() xor 1).toByte()
        val opener = VideoOpener(vectorSecret(), VideoDirection.HostToClient)
        assertThrows(SealException.AuthenticationFailed::class.java) { opener.open(datagram) }
    }

    @Test
    fun aDatagramFromTheOtherDirectionIsRejected() {
        val datagram = relayed(VideoSealer(vectorSecret(), VideoDirection.HostToClient, vectorToken())
            .seal(MessageKind.Ping, pingPayload()).single())
        val opener = VideoOpener(vectorSecret(), VideoDirection.ClientToHost)
        assertThrows(SealException.AuthenticationFailed::class.java) { opener.open(datagram) }
    }

    @Test
    fun aDatagramOutsideTheSizeBoundsIsRejected() {
        val opener = VideoOpener(vectorSecret(), VideoDirection.HostToClient)
        val truncated = assertThrows(SealException.Truncated::class.java) { opener.open(ByteArray(10)) }
        assertEquals(10, truncated.have)
        assertEquals(24, truncated.need)
        assertThrows(SealException.Oversized::class.java) { opener.open(ByteArray(3000)) }
    }
}
