package pl.dmq.peering.wire

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingSasTest {
    private val crypto = VectorFiles.load("crypto.json").jsonObject

    @Test
    fun theTranscriptBytesMatchTheVector() {
        val sas = crypto.section("sas")
        assertEquals(sas.text("transcript"), vectorTranscript().serialized().toHex())
    }

    @Test
    fun theCodeMatchesTheVector() {
        assertEquals("365357", vectorTranscript().code())
    }

    @Test
    fun theCommitmentMatchesTheVectorAndVerifies() {
        val commit = crypto.section("commitment")
        val ephemeral = commit.text("ephemeral").hexToBytes()
        val nonce = commit.text("nonce").hexToBytes()
        val expected = commit.text("commitment").hexToBytes()
        assertArrayEquals(expected, PairingSas.commitment(ephemeral, nonce))
        assertTrue(PairingSas.verifyCommitment(expected, ephemeral, nonce))
    }

    @Test
    fun aCommitmentDoesNotVerifyAgainstAChangedNonce() {
        val commit = crypto.section("commitment")
        val ephemeral = commit.text("ephemeral").hexToBytes()
        val expected = commit.text("commitment").hexToBytes()
        assertFalse(PairingSas.verifyCommitment(expected, ephemeral, "other nonce".toByteArray()))
    }

    @Test
    fun theProofMatchesTheVectorAndVerifies() {
        val proof = crypto.section("proof")
        val secret = proof.text("secret").hexToBytes()
        val expected = proof.text("proof").hexToBytes()
        val transcript = vectorTranscript()
        assertArrayEquals(expected, transcript.proof(secret))
        assertTrue(transcript.verifyProof(expected, secret))
    }

    @Test
    fun aWrongSecretIsRejected() {
        val secret = crypto.section("proof").text("secret").hexToBytes()
        val proof = vectorTranscript().proof(secret)
        assertFalse(vectorTranscript().verifyProof(proof, "another secret!!".toByteArray()))
    }

    @Test
    fun aProofForAnotherTranscriptIsRejected() {
        val secret = crypto.section("proof").text("secret").hexToBytes()
        val proof = vectorTranscript().proof(secret)
        val otherHost = vectorTranscript().copy(serverId = "mac-studio-02")
        assertFalse(otherHost.verifyProof(proof, secret))
    }

    @Test
    fun aProofIsRejectedWhenItIsTheWrongLength() {
        val secret = crypto.section("proof").text("secret").hexToBytes()
        val proof = vectorTranscript().proof(secret)
        assertFalse(vectorTranscript().verifyProof(proof.copyOfRange(0, 31), secret))
    }

    @Test
    fun anEmptySecretIsRefused() {
        val error = runCatching { vectorTranscript().proof(ByteArray(0)) }.exceptionOrNull()
        assertTrue(error is IllegalArgumentException)
    }

    @Test
    fun changingAnyFieldChangesTheTranscriptAndTheCode() {
        val base = vectorTranscript()
        val changed = listOf(
            base.copy(protocolVersion = 2),
            base.copy(clientId = "iphone-15-pro-max2"),
            base.copy(serverId = "mac-studio-01 "),
            base.copy(clientEphemeralPublicKey = ByteArray(65) { 0x11 }),
            base.copy(serverEphemeralPublicKey = ByteArray(65) { 0x22 }),
            base.copy(clientNonce = ByteArray(32) { 0x33 }),
            base.copy(serverNonce = ByteArray(32) { 0x44 }),
            base.copy(serverIdentityPublicKey = ByteArray(65) { 0x55 }),
        )
        for (variant in changed) {
            assertNotEquals(base.serialized().toHex(), variant.serialized().toHex())
        }
        assertNotEquals(base.code(), base.copy(serverNonce = ByteArray(32) { 0x45 }).code())
    }

    @Test
    fun movingABoundaryBetweenFieldsChangesTheTranscript() {
        val base = vectorTranscript()
        val borrowed = base.copy(clientId = "iphone-15-pro-maxm", serverId = "ac-studio-01")
        assertNotEquals(base.serialized().toHex(), borrowed.serialized().toHex())
    }

    @Test
    fun swappingTheClientAndServerIdChangesTheTranscript() {
        val base = vectorTranscript()
        val swapped = base.copy(clientId = base.serverId, serverId = base.clientId)
        assertNotEquals(base.serialized().toHex(), swapped.serialized().toHex())
    }

    @Test
    fun aProtocolVersionOutsideTwoBytesIsRefused() {
        val error = runCatching { vectorTranscript().copy(protocolVersion = 0x10000) }.exceptionOrNull()
        assertTrue(error is IllegalArgumentException)
    }

    private fun vectorTranscript(): PairingTranscript {
        val sas = crypto.section("sas")
        return PairingTranscript(
            protocolVersion = sas["protocolVersion"]!!.jsonPrimitive.content.toInt(),
            clientId = sas.text("clientID"),
            serverId = sas.text("serverID"),
            clientEphemeralPublicKey = sas.text("clientEphemeral").hexToBytes(),
            serverEphemeralPublicKey = sas.text("serverEphemeral").hexToBytes(),
            clientNonce = sas.text("clientNonce").hexToBytes(),
            serverNonce = sas.text("serverNonce").hexToBytes(),
            serverIdentityPublicKey = sas.text("serverIdentity").hexToBytes(),
        )
    }

    private fun JsonObject.text(name: String): String = this[name]!!.jsonPrimitive.content

    private fun JsonObject.section(name: String): JsonObject = this[name]!!.jsonObject
}
