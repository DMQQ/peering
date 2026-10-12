package pl.dmq.peering.wire

import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import pl.dmq.peering.wire.RelayClientMessage.ConnectToHost
import pl.dmq.peering.wire.RelayClientMessage.HostPresence
import pl.dmq.peering.wire.RelayClientMessage.NotifyDevice
import pl.dmq.peering.wire.RelayClientMessage.Ping
import pl.dmq.peering.wire.RelayClientMessage.RegisterHost
import pl.dmq.peering.wire.RelayClientMessage.RequestPeerAddress
import pl.dmq.peering.wire.RelayServerMessage.Error
import pl.dmq.peering.wire.RelayServerMessage.PeerAddress
import pl.dmq.peering.wire.RelayServerMessage.Pong
import pl.dmq.peering.wire.RelayServerMessage.Registered
import pl.dmq.peering.wire.RelayServerMessage.SessionReady

class RelayMessagesTest {
    private val relay = VectorFiles.load("relay.json").jsonObject

    private val typedClientMessages: Map<String, RelayClientMessage> = mapOf(
        "registerHost" to RegisterHost(deviceId = "mac-1", name = "Studio", protocolVersion = 3),
        "connectToHost free" to ConnectToHost(hostId = "mac-1", clientId = "phone-1", protocolVersion = 3),
        "connectToHost plan" to ConnectToHost(
            hostId = "mac-1",
            clientId = "phone-1",
            protocolVersion = 3,
            plan = "relay",
        ),
        "ping" to Ping,
        "requestPeerAddress" to RequestPeerAddress(Token.parse("000102030405060708090a0b0c0d0e0f")!!),
        "hostPresence" to HostPresence(hostId = "mac-1"),
        "notifyDevice" to NotifyDevice(deviceToken = "ab".repeat(32), title = "t", body = "b"),
    )

    private val typedServerMessages: Map<String, RelayServerMessage> = mapOf(
        "sessionReady" to SessionReady(
            controlHost = "relay.getpeering.app",
            controlPort = 20190,
            videoHost = "relay.getpeering.app",
            videoPort = 30190,
            controlToken = Token(ByteArray(16) { it.toByte() }),
            videoToken = Token(ByteArray(16) { (0xff - it).toByte() }),
        ),
        "registered" to Registered(sessionTtlSeconds = 300),
        "hostOffline" to RelayServerMessage.HostOffline(deviceId = "mac-1"),
        "peerAddress" to PeerAddress(host = "203.0.113.5", port = 40_000),
        "hostPresence" to RelayServerMessage.HostPresence(hostId = "mac-1", online = true),
        "pong" to Pong,
        "error" to Error(code = "quotaExceeded", message = "relay allowance exhausted for this period"),
    )

    private fun vectorEntries(section: String) = relay.getValue(section).jsonArray.map {
        it.jsonObject.getValue("name").jsonPrimitive.content to it.jsonObject.getValue("json").jsonPrimitive.content
    }

    @Test
    fun everyClientVectorIsProducedExactlyByItsTypedMessage() {
        val entries = vectorEntries("clientMessages")

        assertEquals(typedClientMessages.keys, entries.map { it.first }.toSet())
        for ((name, json) in entries) {
            assertEquals(name, json, typedClientMessages.getValue(name).toJson())
        }
    }

    @Test
    fun everyServerVectorParsesToItsTypedMessage() {
        val entries = vectorEntries("serverMessages")

        assertEquals(typedServerMessages.keys, entries.map { it.first }.toSet())
        for ((name, json) in entries) {
            assertEquals(name, typedServerMessages.getValue(name), RelayServerMessage.parse(json))
        }
    }

    @Test
    fun validTokenVectorsParseAndReturnLowercaseHex() {
        val tokens = relay.getValue("tokens").jsonObject.getValue("valid").jsonArray.map { it.jsonPrimitive.content }

        for (text in tokens) {
            assertEquals(text.lowercase(), Token.parse(text)?.toHex())
        }
    }

    @Test
    fun invalidTokenVectorsAreRejected() {
        val tokens = relay.getValue("tokens").jsonObject.getValue("invalid").jsonArray.map { it.jsonPrimitive.content }

        for (text in tokens) {
            assertNull("token '$text'", Token.parse(text))
        }
    }

    @Test
    fun aTokenRejectsSignsSpacesAndNonAsciiDigits() {
        val base = "000102030405060708090a0b0c0d0e0f"
        val rejected = listOf(
            "+" + base.drop(1),
            " " + base.drop(1),
            base.dropLast(1) + "١",
            base.dropLast(1) + "-",
        )

        for (text in rejected) {
            assertNull("token '$text'", Token.parse(text))
        }
    }

    @Test
    fun aTokenEqualsAnotherWithTheSameBytes() {
        assertEquals(Token.parse("ABCDEF0123456789ABCDEF0123456789"), Token.parse("abcdef0123456789abcdef0123456789"))
    }

    @Test
    fun anUnknownServerTypeDecodesAsUnknown() {
        assertEquals(RelayServerMessage.Unknown("futureThing"), RelayServerMessage.parse("{\"type\":\"futureThing\",\"x\":1}"))
    }

    @Test
    fun absentOptionalFieldsAreLeftOutOfTheJson() {
        val json = ConnectToHost(hostId = "mac-1", clientId = "phone-1", protocolVersion = 3).toJson()

        assertEquals(false, json.contains("plan"))
        assertEquals(false, json.contains("playPurchaseToken"))
        assertEquals(false, json.contains("playProductId"))
    }

    @Test
    fun presentOptionalFieldsAreWrittenInSortedOrder() {
        val json = ConnectToHost(
            hostId = "mac-1",
            clientId = "phone-1",
            protocolVersion = 20,
            playProductId = "app.getpeering.relay",
            playPurchaseToken = "token-1",
        ).toJson()

        assertEquals(
            "{\"clientId\":\"phone-1\",\"hostId\":\"mac-1\",\"playProductId\":\"app.getpeering.relay\"," +
                "\"playPurchaseToken\":\"token-1\",\"protocolVersion\":20,\"type\":\"connectToHost\"}",
            json,
        )
    }

    @Test
    fun aConnectWithoutAProofLeavesTheProofMembersOut() {
        val json = ConnectToHost(hostId = "mac-1", clientId = "phone-1", protocolVersion = 20).toJson()

        assertEquals(false, json.contains("publicKey"))
        assertEquals(false, json.contains("\"proof\""))
        assertEquals(false, json.contains("proofTime"))
    }

    @Test
    fun aConnectWithAProofWritesTheThreeProofMembers() {
        val json = ConnectToHost(
            hostId = "mac-1",
            clientId = "phone-1",
            protocolVersion = 20,
            publicKey = "04aa",
            proof = "3044",
            proofTime = 1_760_000_000,
        ).toJson()

        assertEquals(
            "{\"clientId\":\"phone-1\",\"hostId\":\"mac-1\",\"proof\":\"3044\",\"proofTime\":1760000000," +
                "\"protocolVersion\":20,\"publicKey\":\"04aa\",\"type\":\"connectToHost\"}",
            json,
        )
    }

    @Test
    fun aRegisterWithAProofWritesTheThreeProofMembers() {
        val json = RegisterHost(
            deviceId = "mac-1",
            name = "Studio",
            protocolVersion = 20,
            publicKey = "04aa",
            proof = "3044",
            proofTime = 1_760_000_000,
        ).toJson()

        assertEquals(
            "{\"deviceId\":\"mac-1\",\"name\":\"Studio\",\"proof\":\"3044\",\"proofTime\":1760000000," +
                "\"protocolVersion\":20,\"publicKey\":\"04aa\",\"type\":\"registerHost\"}",
            json,
        )
    }

    @Test
    fun aNonObjectOrMalformedServerMessageThrows() {
        assertThrows(RelayMessageException::class.java) { RelayServerMessage.parse("not json") }
        assertThrows(RelayMessageException::class.java) { RelayServerMessage.parse("[1,2]") }
        assertThrows(RelayMessageException::class.java) { RelayServerMessage.parse("{\"sessionTtlSeconds\":1}") }
    }

    @Test
    fun aSessionReadyDecodesWithAndWithoutRemainingSeconds() {
        val base = "\"type\":\"sessionReady\",\"controlHost\":\"h\",\"controlPort\":1,\"videoHost\":\"h\"," +
            "\"videoPort\":2,\"controlToken\":\"000102030405060708090a0b0c0d0e0f\"," +
            "\"videoToken\":\"000102030405060708090a0b0c0d0e0f\""

        val without = RelayServerMessage.parse("{$base}") as SessionReady
        val with = RelayServerMessage.parse("{$base,\"remainingSeconds\":1703}") as SessionReady

        assertNull(without.remainingSeconds)
        assertEquals(1703L, with.remainingSeconds)
    }

    @Test
    fun aSessionReadyWithAMalformedTokenThrows() {
        val text = "{\"type\":\"sessionReady\",\"controlHost\":\"h\",\"controlPort\":1,\"videoHost\":\"h\"," +
            "\"videoPort\":2,\"controlToken\":\"0001\",\"videoToken\":\"000102030405060708090a0b0c0d0e0f\"}"

        assertThrows(RelayMessageException::class.java) { RelayServerMessage.parse(text) }
    }

    @Test
    fun aPortOutsideTheTcpRangeThrows() {
        val text = "{\"type\":\"peerAddress\",\"host\":\"203.0.113.5\",\"port\":70000}"

        assertThrows(RelayMessageException::class.java) { RelayServerMessage.parse(text) }
    }
}
