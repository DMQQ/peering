package pl.dmq.peering.wire

import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class RelayProofTest {
    private val vectors = VectorFiles.load("crypto.json").jsonObject.getValue("relayProofPayloads").jsonObject

    private fun vector(name: String): ByteArray = vectors.getValue(name).jsonPrimitive.content.toByteArray(Charsets.UTF_8)

    private class RecordingSigner(
        private val publicKey: ByteArray,
        private val signature: ByteArray,
    ) : ProofSigner {
        val signedMessages = mutableListOf<ByteArray>()

        override fun publicKey(): ByteArray = publicKey

        override fun sign(message: ByteArray): ByteArray {
            signedMessages += message
            return signature
        }
    }

    @Test
    fun hostPayloadMatchesTheSharedVector() {
        assertArrayEquals(vector("host"), hostPayload("DEV", 1_760_000_000))
    }

    @Test
    fun clientPayloadMatchesTheSharedVector() {
        assertArrayEquals(vector("client"), clientPayload("CLI", 1_760_000_000))
    }

    @Test
    fun referralStatusPayloadMatchesTheSharedVector() {
        assertArrayEquals(vector("referralStatus"), referralStatusPayload("CLI", 1_760_000_000))
    }

    @Test
    fun redeemReferralPayloadMatchesTheSharedVector() {
        assertArrayEquals(vector("referralRedeem"), redeemReferralPayload("CLI", "ABCD", 1_760_000_000))
    }

    @Test
    fun leadingZeroBytesAreKeptInTheHexOfAProof() {
        val proof = DeviceProof.fromBytes(
            publicKey = byteArrayOf(0x00, 0x01, 0x0f, 0x7f),
            derSignature = byteArrayOf(0x00, 0xab.toByte()),
            proofTime = 1_760_000_000,
        )

        assertEquals("00010f7f", proof.publicKey)
        assertEquals("00ab", proof.signature)
        assertEquals(1_760_000_000L, proof.proofTime)
    }

    @Test
    fun hostProofSignsExactlyTheHostPayload() {
        val signer = RecordingSigner(publicKey = byteArrayOf(0x04, 0x00), signature = byteArrayOf(0x30, 0x06))

        val proof = makeHostProof(signer, "DEV", 1_760_000_000)

        assertEquals(1, signer.signedMessages.size)
        assertArrayEquals(vector("host"), signer.signedMessages.single())
        assertEquals("0400", proof.publicKey)
        assertEquals("3006", proof.signature)
        assertEquals(1_760_000_000L, proof.proofTime)
    }

    @Test
    fun clientProofSignsExactlyTheClientPayload() {
        val signer = RecordingSigner(publicKey = byteArrayOf(0x04), signature = byteArrayOf(0x30))

        makeClientProof(signer, "CLI", 1_760_000_000)

        assertArrayEquals(vector("client"), signer.signedMessages.single())
    }

    @Test
    fun aHostProofSignsADifferentDomainFromAClientProofForTheSameId() {
        val signer = RecordingSigner(publicKey = byteArrayOf(0x04), signature = byteArrayOf(0x30))

        makeHostProof(signer, "CLI", 1_760_000_000)

        assertFalse(signer.signedMessages.single().contentEquals(clientPayload("CLI", 1_760_000_000)))
    }
}
