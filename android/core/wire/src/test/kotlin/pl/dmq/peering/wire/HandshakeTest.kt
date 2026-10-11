package pl.dmq.peering.wire

import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HandshakeTest {
    private val cases: List<Pair<String, String>> = VectorFiles.load("messages.json")
        .jsonObject.getValue("cases").jsonArray.map {
            val case = it.jsonObject
            case.getValue("name").jsonPrimitive.content to case.getValue("json").jsonPrimitive.content
        }

    private inline fun <reified T> assertVectorsRoundTrip(prefix: String) {
        val matching = cases.filter { (name, _) -> name.startsWith(prefix) }
        assertTrue("no vector named $prefix", matching.isNotEmpty())
        for ((name, json) in matching) {
            val encoded = WireJson.encodeToString(WireJson.decodeFromString<T>(json))
            assertTrue("$name re-encodes to $encoded", jsonEquals(encoded, json))
        }
    }

    @Test
    fun clientHelloVectorsRoundTrip() = assertVectorsRoundTrip<ClientHello>("clientHello")

    @Test
    fun serverHelloVectorsRoundTrip() = assertVectorsRoundTrip<ServerHello>("serverHello")

    @Test
    fun pairCommitVectorRoundTrips() = assertVectorsRoundTrip<PairingCommit>("pairCommit")

    @Test
    fun pairRevealVectorRoundTrips() = assertVectorsRoundTrip<PairingReveal>("pairReveal")

    @Test
    fun pairConfirmVectorsRoundTrip() = assertVectorsRoundTrip<PairConfirm>("pairConfirm")

    @Test
    fun pairResultVectorsRoundTrip() = assertVectorsRoundTrip<PairResult>("pairResult")

    @Test
    fun errorVectorsRoundTrip() = assertVectorsRoundTrip<ErrorPayload>("error")

    @Test
    fun noticeVectorRoundTrips() = assertVectorsRoundTrip<NoticePayload>("notice")

    @Test
    fun pingVectorRoundTrips() = assertVectorsRoundTrip<PingPayload>("ping")

    @Test
    fun videoKeyVectorRoundTrips() = assertVectorsRoundTrip<VideoKeyGrant>("videoKey")

    @Test
    fun videoTransportVectorRoundTrips() = assertVectorsRoundTrip<VideoTransportRequest>("videoTransport")

    @Test
    fun missingCapabilityFlagsDecodeAsNull() {
        val hello = WireJson.decodeFromString<ClientHello>(
            """{"clientID":"c","clientName":"p","protocolVersion":20,"wantsPairing":false}""",
        )
        assertNull(hello.supportsAgentChat)
        assertNull(hello.lostPairing)
        assertNull(hello.resumeSource)

        val server = WireJson.decodeFromString<ServerHello>(
            """{"serverID":"s","hostName":"h","protocolVersion":20,"alreadyPaired":true}""",
        )
        assertNull(server.supportsVideoPause)
        assertNull(server.macAddresses)
        assertNull(server.agentChatAgents)
    }

    @Test
    fun explicitNullFlagsDecodeAsNull() {
        val hello = WireJson.decodeFromString<ClientHello>(
            """{"clientID":"c","clientName":"p","protocolVersion":20,"wantsPairing":true,"supportsAgentChat":null}""",
        )
        assertNull(hello.supportsAgentChat)
    }

    @Test
    fun unsetFlagsAreAbsentWhenEncoded() {
        val hello = ClientHello(clientID = "c", clientName = "p", protocolVersion = 20, wantsPairing = false)
        assertEquals(
            """{"clientID":"c","clientName":"p","protocolVersion":20,"wantsPairing":false}""",
            WireJson.encodeToString(hello),
        )
        val server = ServerHello(serverID = "s", hostName = "h", protocolVersion = 20, alreadyPaired = true)
        assertEquals(
            """{"serverID":"s","hostName":"h","protocolVersion":20,"alreadyPaired":true}""",
            WireJson.encodeToString(server),
        )
    }

    @Test
    fun unknownKeysAreIgnored() {
        val accept = WireJson.decodeFromString<PairResult>("""{"accepted":true,"futureField":[1,2]}""")
        assertTrue(accept.accepted)
        assertNull(accept.reason)
    }

    @Test
    fun byteFieldsDecodeFromBase64() {
        val reveal = WireJson.decodeFromString<PairingReveal>("""{"ephemeralPublicKey":"AQI=","nonce":"AwQ="}""")
        assertArrayEquals(byteArrayOf(1, 2), reveal.ephemeralPublicKeyBytes)
        assertArrayEquals(byteArrayOf(3, 4), reveal.nonceBytes)
    }

    @Test
    fun absentProofIsNullBytes() {
        val confirm = WireJson.decodeFromString<PairConfirm>("""{"accepted":true}""")
        assertNull(confirm.proofBytes)
    }

    @Test
    fun pairedHostTrustsAPinnedKeyUnlessThePhoneLostThePin() {
        assertTrue(ClientHello.hostTreatsAsPaired(pinned = true, lostPairing = null))
        assertTrue(ClientHello.hostTreatsAsPaired(pinned = true, lostPairing = false))
        assertFalse(ClientHello.hostTreatsAsPaired(pinned = true, lostPairing = true))
        assertFalse(ClientHello.hostTreatsAsPaired(pinned = false, lostPairing = null))
    }

    @Test
    fun hostStoppedCodeMatchesTheHost() {
        val error = WireJson.decodeFromString<ErrorPayload>("""{"code":"hostStopped","message":"stopped"}""")
        assertEquals(ErrorPayload.HOST_STOPPED_CODE, error.code)
    }

    @Test
    fun transportNamesAreLowercaseOnTheWire() {
        val request = WireJson.decodeFromString<VideoTransportRequest>("""{"reason":"r","transport":"control"}""")
        assertEquals(VideoTransportKind.CONTROL, request.transport)
    }
}
