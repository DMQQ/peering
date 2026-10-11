package pl.dmq.peering.session.flows

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import pl.dmq.peering.session.connection.ClientAction
import pl.dmq.peering.session.connection.ClientConfig
import pl.dmq.peering.session.connection.ClientHandshakeState
import pl.dmq.peering.session.connection.ClientStateMachine
import pl.dmq.peering.session.connection.FailureReason
import pl.dmq.peering.session.relay.RelayConnect
import pl.dmq.peering.session.relay.RelaySessionException
import pl.dmq.peering.session.testing.FakePinStore
import pl.dmq.peering.session.testing.FakeSignalling
import pl.dmq.peering.session.testing.FixedRandom
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.FrameDecoder
import pl.dmq.peering.wire.FrameEncoder
import pl.dmq.peering.wire.FrameTooLarge
import pl.dmq.peering.wire.MAX_FRAME_LENGTH
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.PROTOCOL_VERSION
import pl.dmq.peering.wire.RelayServerMessage
import pl.dmq.peering.wire.ServerHello
import pl.dmq.peering.wire.UnknownKind
import pl.dmq.peering.wire.WireJson

class ErrorPathsTest {
    private fun phone(store: FakePinStore = FakePinStore()) = ClientStateMachine(
        ClientConfig(CLIENT_ID, "Phone", null, ScriptedPairingHost.HOST_KEY),
        store,
        FixedRandom(1),
    )

    private fun serverHello(version: Int) = Frame(
        MessageKind.ServerHello,
        WireJson.encodeToString(
            ServerHello.serializer(),
            ServerHello(ScriptedPairingHost.HOST_ID, "Studio", version, alreadyPaired = false),
        ).toByteArray(Charsets.UTF_8),
    )

    @Test
    fun aHostOnAnotherProtocolVersionEndsTheHandshakeNamingBothVersions() {
        val machine = phone()
        machine.start()
        val actions = machine.onFrame(serverHello(PROTOCOL_VERSION - 1))

        assertEquals(
            listOf<ClientAction>(ClientAction.Failed(FailureReason.ProtocolMismatch(PROTOCOL_VERSION, PROTOCOL_VERSION - 1))),
            actions,
        )
        assertEquals(ClientHandshakeState.Failed, machine.state)
    }

    @Test
    fun aRelayOnAnotherVersionIsAVersionMismatch() = runTest {
        val signalling = FakeSignalling()
        signalling.reply(RelayServerMessage.Error("version", "relay is older"))

        val failure = runCatching { RelayConnect(signalling).requestSession(ScriptedPairingHost.HOST_ID, CLIENT_ID) }
            .exceptionOrNull()

        assertEquals(RelaySessionException.VersionMismatch, failure)
        assertEquals(
            "The relay and this app speak different protocol versions.",
            failure?.message,
        )
    }

    @Test
    fun aRelayThatHasUsedUpTheFreeTimeReportsQuotaExceeded() = runTest {
        val signalling = FakeSignalling()
        signalling.reply(RelayServerMessage.Error("quotaExceeded", "free time used"))

        val failure = runCatching { RelayConnect(signalling).requestSession(ScriptedPairingHost.HOST_ID, CLIENT_ID) }
            .exceptionOrNull()

        assertEquals(RelaySessionException.QuotaExceeded, failure)
        assertEquals("The relay's free time is used up for today.", failure?.message)
    }

    @Test
    fun aFrameOfAnUnknownKindIsRefusedAtTheDecoder() {
        val decoder = FrameDecoder()
        decoder.push(byteArrayOf(0, 0, 0, 1, UNKNOWN_KIND_BYTE))

        val error = assertThrows(UnknownKind::class.java) { decoder.next() }
        assertEquals(UNKNOWN_KIND_BYTE.toInt() and 0xFF, error.byte)
    }

    @Test
    fun aFrameDeclaringMoreThanTheLimitIsRefusedBeforeItsPayloadArrives() {
        val decoder = FrameDecoder()
        val declared = MAX_FRAME_LENGTH + 1
        decoder.push(byteArrayOf((declared ushr 24).toByte(), (declared ushr 16).toByte(), (declared ushr 8).toByte(), declared.toByte()))

        val error = assertThrows(FrameTooLarge::class.java) { decoder.next() }
        assertEquals(declared, error.declared)
        assertEquals(LENGTH_PREFIX_BYTES, decoder.buffered)
    }

    @Test
    fun aControlPayloadOverTheLimitIsNotFramedForTheWire() {
        assertThrows(IllegalArgumentException::class.java) {
            FrameEncoder.encode(MessageKind.Command, ByteArray(MAX_FRAME_LENGTH.toInt()))
        }
    }

    @Test
    fun aMalformedHandshakeBodyEndsTheSessionAndLaterFramesAreIgnored() {
        val machine = phone()
        machine.start()
        val actions = machine.onFrame(Frame(MessageKind.ServerHello, "not json".toByteArray()))

        assertEquals(listOf<ClientAction>(ClientAction.Failed(FailureReason.MalformedMessage(MessageKind.ServerHello))), actions)
        assertEquals(ClientHandshakeState.Failed, machine.state)
        assertEquals(emptyList<ClientAction>(), machine.onFrame(serverHello(PROTOCOL_VERSION)))
    }

    @Test
    fun aFrameOfTheWrongKindEndsTheHandshake() {
        val machine = phone()
        machine.start()
        val actions = machine.onFrame(Frame(MessageKind.Ping, "{\"sequence\":1}".toByteArray()))

        assertEquals(
            listOf<ClientAction>(ClientAction.Failed(FailureReason.UnexpectedFrame(MessageKind.Ping, "serverHello"))),
            actions,
        )
    }

    @Test
    fun anUnknownEnumCaseFromTheHostAfterReadyIsIgnoredAndTheSessionStays() {
        val pinned = FakePinStore(mapOf(ScriptedPairingHost.HOST_ID to ScriptedPairingHost.HOST_KEY))
        val machine = phone(store = pinned)
        val link = PairingLink(machine, ScriptedPairingHost(alreadyPaired = true))
        link.start()
        assertNotNull(link.actions.filterIsInstance<ClientAction.Ready>().singleOrNull())

        val unknownCase = Frame(MessageKind.AgentEvent, """{"someFutureCase":{"_0":"x"}}""".toByteArray())
        assertThrows(Exception::class.java) { AgentEvent.parse(unknownCase.payload.decodeToString()) }

        assertEquals(emptyList<ClientAction>(), machine.onFrame(unknownCase))
        assertEquals(ClientHandshakeState.Ready, machine.state)
        assertNull(link.actions.filterIsInstance<ClientAction.Failed>().singleOrNull())
    }

    private companion object {
        const val CLIENT_ID = "11111111-2222-4333-8444-555555555555"
        const val UNKNOWN_KIND_BYTE: Byte = 0xEE.toByte()
        const val LENGTH_PREFIX_BYTES = 4
    }
}
