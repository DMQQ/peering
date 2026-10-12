package pl.dmq.peering.session.connection

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.testing.FakePinStore
import pl.dmq.peering.session.testing.FixedRandom
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.ClientHello
import pl.dmq.peering.wire.ConnectionRole
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.PairConfirm
import pl.dmq.peering.wire.PairingCommit
import pl.dmq.peering.wire.PairingReveal
import pl.dmq.peering.wire.PairingSas
import pl.dmq.peering.wire.PairingTranscript
import pl.dmq.peering.wire.PROTOCOL_VERSION
import pl.dmq.peering.wire.WireJson
import pl.dmq.peering.wire.fromBase64

class ClientStateMachineTest {
    private val clientEphemeral = ByteArray(65) { 1 }.also { it[0] = 0x04 }
    private val clientNonce = ByteArray(32) { 1 }

    private fun machine(
        pins: FakePinStore = FakePinStore(),
        dialled: String? = null,
        serverKey: ByteArray = HostFrames.hostKey,
    ) = ClientStateMachine(
        ClientConfig(HostFrames.CLIENT_ID, "Phone", dialled, serverKey),
        pins,
        FixedRandom(1),
    )

    private fun ClientAction.sentFrame(): Frame = (this as ClientAction.Send).frame

    private fun transcript() = PairingTranscript(
        protocolVersion = PROTOCOL_VERSION,
        clientId = HostFrames.CLIENT_ID,
        serverId = HostFrames.HOST_ID,
        clientEphemeralPublicKey = clientEphemeral,
        serverEphemeralPublicKey = HostFrames.hostEphemeral,
        clientNonce = clientNonce,
        serverNonce = HostFrames.hostNonce,
        serverIdentityPublicKey = HostFrames.hostKey,
    )

    /** Drives a fresh machine to the six digits, returning it with the code it showed. */
    private fun pairingToCode(machine: ClientStateMachine): String {
        machine.start()
        machine.onFrame(HostFrames.serverHello())
        machine.onFrame(HostFrames.commit())
        val shown = machine.onFrame(HostFrames.reveal())
        return (shown.single() as ClientAction.ShowCode).code
    }

    @Test
    fun startSendsTheConnectionRoleThenAClientHello() {
        val actions = machine().start()

        val role = actions[0].sentFrame()
        assertEquals(MessageKind.ConnectionRole, role.kind)
        assertArrayEquals(byteArrayOf(ConnectionRole.Control.byte.toByte()), role.payload)

        val hello = WireJson.decodeFromString(ClientHello.serializer(), actions[1].sentFrame().payload.decodeToString())
        assertEquals(HostFrames.CLIENT_ID, hello.clientID)
        assertEquals(PROTOCOL_VERSION, hello.protocolVersion)
        assertTrue(hello.wantsPairing)
        assertNull(hello.lostPairing)
    }

    @Test
    fun theHelloToAKnownHostCarriesTheResumeSourceAndThePlatformAndCodecs() {
        val config = ClientConfig(
            HostFrames.CLIENT_ID,
            "Phone",
            HostFrames.HOST_ID,
            HostFrames.hostKey,
            resumeSource = CaptureSource.Display(7).toJson(),
            clientPlatform = "android",
            videoCodecs = listOf("hevc", "h264"),
        )
        val pins = FakePinStore(mapOf(HostFrames.HOST_ID to HostFrames.hostKey))
        val actions = ClientStateMachine(config, pins, FixedRandom(1)).start()

        val hello = WireJson.decodeFromString(ClientHello.serializer(), actions[1].sentFrame().payload.decodeToString())
        assertEquals(CaptureSource.Display(7).toJson(), hello.resumeSource)
        assertEquals("android", hello.clientPlatform)
        assertEquals(listOf("hevc", "h264"), hello.videoCodecs)
    }

    @Test
    fun theHelloToAnUnknownHostCarriesNoResumeSource() {
        val config = ClientConfig(
            HostFrames.CLIENT_ID,
            "Phone",
            null,
            HostFrames.hostKey,
            resumeSource = CaptureSource.Display(7).toJson(),
        )
        val actions = ClientStateMachine(config, FakePinStore(), FixedRandom(1)).start()

        val hello = WireJson.decodeFromString(ClientHello.serializer(), actions[1].sentFrame().payload.decodeToString())
        assertNull(hello.resumeSource)
    }

    @Test
    fun theHelloDoesNotDeclareTheTextFocusAndFieldStateFramesItDropsButDeclaresThePointerReport() {
        val actions = machine().start()

        val hello = WireJson.decodeFromString(ClientHello.serializer(), actions[1].sentFrame().payload.decodeToString())
        assertNull(hello.supportsTextFocus)
        assertNull(hello.supportsFieldState)
        assertEquals(true, hello.supportsPointerReport)
    }

    @Test
    fun aHostPinnedAndDialledDoesNotAskForPairing() {
        val pins = FakePinStore(mapOf(HostFrames.HOST_ID to HostFrames.hostKey))
        val actions = machine(pins, dialled = HostFrames.HOST_ID).start()

        val hello = WireJson.decodeFromString(ClientHello.serializer(), actions[1].sentFrame().payload.decodeToString())
        assertFalse(hello.wantsPairing)
        assertNull(hello.lostPairing)
    }

    @Test
    fun aDialledHostWithNoPinAsksToBeTreatedAsLostPairing() {
        val actions = machine(dialled = HostFrames.HOST_ID).start()

        val hello = WireJson.decodeFromString(ClientHello.serializer(), actions[1].sentFrame().payload.decodeToString())
        assertEquals(true, hello.lostPairing)
    }

    @Test
    fun pairedHostWithAMatchingPinIsReadyWithoutPairing() {
        val pins = FakePinStore(mapOf(HostFrames.HOST_ID to HostFrames.hostKey))
        val machine = machine(pins)
        machine.start()

        val actions = machine.onFrame(HostFrames.serverHello(alreadyPaired = true))

        assertEquals(1, actions.size)
        assertEquals(HostFrames.HOST_ID, (actions.single() as ClientAction.Ready).hello.serverID)
        assertEquals(ClientHandshakeState.Ready, machine.state)
    }

    @Test
    fun sasPairingAcceptedSavesThePinAndIsReady() {
        val pins = FakePinStore()
        val machine = machine(pins)
        machine.start()

        val commitAction = machine.onFrame(HostFrames.serverHello()).single()
        val commit = WireJson.decodeFromString(PairingCommit.serializer(), (commitAction as ClientAction.Send).frame.payload.decodeToString())
        assertArrayEquals(PairingSas.commitment(clientEphemeral, clientNonce), commit.commitmentBytes)

        val revealAction = machine.onFrame(HostFrames.commit()).single().sentFrame()
        val reveal = WireJson.decodeFromString(PairingReveal.serializer(), revealAction.payload.decodeToString())
        assertArrayEquals(clientEphemeral, reveal.ephemeralPublicKeyBytes)
        assertArrayEquals(clientNonce, reveal.nonceBytes)

        val shown = machine.onFrame(HostFrames.reveal())
        assertEquals(listOf<ClientAction>(ClientAction.ShowCode(transcript().code())), shown)
        assertEquals(ClientHandshakeState.AwaitingUserConfirmation, machine.state)

        val confirm = machine.confirm(accepted = true, secret = null)
        val sent = WireJson.decodeFromString(PairConfirm.serializer(), confirm.single().sentFrame().payload.decodeToString())
        assertTrue(sent.accepted)
        assertNull(sent.proof)

        val done = machine.onFrame(HostFrames.pairResult(accepted = true))
        assertEquals(listOf(ClientAction.PinRecorded, ClientAction.Ready(done.filterIsInstance<ClientAction.Ready>().single().hello)), done)
        assertArrayEquals(HostFrames.hostKey, pins.pin(HostFrames.HOST_ID))
        assertEquals(ClientHandshakeState.Ready, machine.state)
    }

    @Test
    fun theUserRejectingTheCodeSendsARefusalAndFailsWithoutPinning() {
        val pins = FakePinStore()
        val machine = machine(pins)
        pairingToCode(machine)

        val actions = machine.confirm(accepted = false, secret = null)

        val sent = WireJson.decodeFromString(PairConfirm.serializer(), actions[0].sentFrame().payload.decodeToString())
        assertFalse(sent.accepted)
        assertEquals(listOf(ClientAction.Failed(FailureReason.PairingDeclined)), actions.drop(1))
        assertNull(pins.pin(HostFrames.HOST_ID))
        assertEquals(ClientHandshakeState.Failed, machine.state)
    }

    @Test
    fun aScannedSecretSendsAProofOverTheTranscript() {
        val machine = machine()
        pairingToCode(machine)
        val secret = ByteArray(16) { 0x5A }

        val actions = machine.confirm(accepted = true, secret = secret)

        val sent = WireJson.decodeFromString(PairConfirm.serializer(), actions.single().sentFrame().payload.decodeToString())
        assertArrayEquals(transcript().proof(secret), checkNotNull(sent.proof).fromBase64())
    }

    @Test
    fun aVersionMismatchFailsBeforeAnythingIsPinned() {
        val pins = FakePinStore()
        val machine = machine(pins)
        machine.start()

        val actions = machine.onFrame(HostFrames.serverHello(version = PROTOCOL_VERSION - 1))

        assertEquals(listOf(ClientAction.Failed(FailureReason.ProtocolMismatch(PROTOCOL_VERSION, PROTOCOL_VERSION - 1))), actions)
        assertEquals(ClientHandshakeState.Failed, machine.state)
    }

    @Test
    fun aHostAnsweringForAnotherIdFailsTheDialledId() {
        val machine = machine(dialled = "PHONE-DIALLED-ID")
        machine.start()

        val actions = machine.onFrame(HostFrames.serverHello(serverId = HostFrames.HOST_ID))

        assertEquals(
            listOf(ClientAction.Failed(FailureReason.HostIdMismatch("PHONE-DIALLED-ID", HostFrames.HOST_ID))),
            actions,
        )
    }

    @Test
    fun aPinnedKeyThatDiffersFromTheTransportKeyFails() {
        val pins = FakePinStore(mapOf(HostFrames.HOST_ID to ByteArray(65) { 0x9 }))
        val machine = machine(pins)
        machine.start()

        val actions = machine.onFrame(HostFrames.serverHello(alreadyPaired = true))

        assertEquals(listOf(ClientAction.Failed(FailureReason.PinMismatch(HostFrames.HOST_ID))), actions)
    }

    @Test
    fun aPinnedHostThatIsNotPairedGoesThroughPairingAgain() {
        val pins = FakePinStore(mapOf(HostFrames.HOST_ID to HostFrames.hostKey))
        val machine = machine(pins)
        machine.start()

        val actions = machine.onFrame(HostFrames.serverHello(alreadyPaired = false))

        assertEquals(ClientHandshakeState.AwaitingServerCommit, machine.state)
        assertEquals(MessageKind.PairCommit, actions.single().sentFrame().kind)
    }

    @Test
    fun aClaimOfPairingWithNoPinOnFileIsRefused() {
        val machine = machine()
        machine.start()

        val actions = machine.onFrame(HostFrames.serverHello(alreadyPaired = true))

        assertEquals(listOf(ClientAction.Failed(FailureReason.NoPinOnFile(HostFrames.HOST_ID))), actions)
    }

    @Test
    fun aHostRefusalCarriesItsReasonAndPinsNothing() {
        val pins = FakePinStore()
        val machine = machine(pins)
        pairingToCode(machine)
        machine.confirm(accepted = true, secret = null)

        val actions = machine.onFrame(HostFrames.pairResult(accepted = false, reason = "Another phone is pairing"))

        assertEquals(listOf(ClientAction.Failed(FailureReason.PairingRefused("Another phone is pairing"))), actions)
        assertNull(pins.pin(HostFrames.HOST_ID))
    }

    @Test
    fun aPinThatCannotBeSavedFailsInsteadOfReady() {
        val pins = FakePinStore()
        pins.writesSucceed = false
        val machine = machine(pins)
        pairingToCode(machine)
        machine.confirm(accepted = true, secret = null)

        val actions = machine.onFrame(HostFrames.pairResult(accepted = true))

        assertEquals(listOf(ClientAction.Failed(FailureReason.PairingNotSaved)), actions)
        assertEquals(ClientHandshakeState.Failed, machine.state)
    }

    @Test
    fun aRevealThatDoesNotMatchTheCommitmentFails() {
        val machine = machine()
        machine.start()
        machine.onFrame(HostFrames.serverHello())
        machine.onFrame(HostFrames.commit())

        val actions = machine.onFrame(HostFrames.reveal(nonce = ByteArray(32) { 0x44 }))

        assertEquals(listOf(ClientAction.Failed(FailureReason.CommitmentMismatch)), actions)
    }

    @Test
    fun aFrameOfTheWrongKindWhileAwaitingTheHelloFails() {
        val machine = machine()
        machine.start()

        val actions = machine.onFrame(HostFrames.commit())

        assertEquals(
            listOf(ClientAction.Failed(FailureReason.UnexpectedFrame(MessageKind.PairCommit, "serverHello"))),
            actions,
        )
    }

    @Test
    fun aHelloThatDoesNotParseFailsAsMalformed() {
        val machine = machine()
        machine.start()

        val actions = machine.onFrame(HostFrames.malformed(MessageKind.ServerHello))

        assertEquals(listOf(ClientAction.Failed(FailureReason.MalformedMessage(MessageKind.ServerHello))), actions)
    }
}
