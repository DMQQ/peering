package pl.dmq.peering.session.flows

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.connection.ClientAction
import pl.dmq.peering.session.connection.ClientConfig
import pl.dmq.peering.session.connection.ClientHandshakeState
import pl.dmq.peering.session.connection.ClientStateMachine
import pl.dmq.peering.session.connection.FailureReason
import pl.dmq.peering.session.testing.FakePinStore
import pl.dmq.peering.session.testing.FixedRandom
import pl.dmq.peering.wire.MessageKind

class PairingFlowTest {
    private val pins = FakePinStore()

    private fun phone(dialled: String? = null, store: FakePinStore = pins) = ClientStateMachine(
        ClientConfig(CLIENT_ID, "Phone", dialled, ScriptedPairingHost.HOST_KEY),
        store,
        FixedRandom(1),
    )

    private fun link(
        machine: ClientStateMachine,
        host: ScriptedPairingHost,
    ) = PairingLink(machine, host)

    private fun PairingLink.shownCode(): String = actions.filterIsInstance<ClientAction.ShowCode>().single().code

    private fun PairingLink.readyHello() = actions.filterIsInstance<ClientAction.Ready>().singleOrNull()?.hello

    private fun PairingLink.failure(): FailureReason? = actions.filterIsInstance<ClientAction.Failed>().singleOrNull()?.reason

    @Test
    fun matchingDigitsAcceptedByTheHostPinTheHost() {
        val host = ScriptedPairingHost()
        val pairing = link(phone(), host)
        pairing.start()

        assertEquals(host.shownCode, pairing.shownCode())
        assertNull(pins.pin(ScriptedPairingHost.HOST_ID))

        pairing.confirm(accepted = true)

        assertEquals(MessageKind.PairConfirm, host.receivedKinds.last())
        assertEquals(true, host.confirmation?.accepted)
        assertEquals(ScriptedPairingHost.HOST_ID, pairing.readyHello()?.serverID)
        assertArrayEquals(ScriptedPairingHost.HOST_KEY, pins.pin(ScriptedPairingHost.HOST_ID))
        assertTrue(pairing.actions.contains(ClientAction.PinRecorded))
        assertNull(pairing.failure())
    }

    @Test
    fun rejectingTheDigitsSendsADeclineAndPinsNothing() {
        val host = ScriptedPairingHost()
        val machine = phone()
        val pairing = link(machine, host)
        pairing.start()
        pairing.confirm(accepted = false)

        assertEquals(false, host.confirmation?.accepted)
        assertEquals(FailureReason.PairingDeclined, pairing.failure())
        assertNull(pins.pin(ScriptedPairingHost.HOST_ID))
        assertEquals(ClientHandshakeState.Failed, machine.state)
    }

    @Test
    fun aScannedSecretProvedToTheHostIsAccepted() {
        val secret = ByteArray(32) { 0x5A }
        val host = ScriptedPairingHost(qrSecret = secret)
        val pairing = link(phone(), host)
        pairing.start()
        pairing.confirm(accepted = true, secret = secret)

        assertTrue(host.confirmation?.proofBytes != null)
        assertEquals(ScriptedPairingHost.HOST_ID, pairing.readyHello()?.serverID)
        assertArrayEquals(ScriptedPairingHost.HOST_KEY, pins.pin(ScriptedPairingHost.HOST_ID))
    }

    @Test
    fun aSecretTheHostDoesNotKnowIsRefusedAndPinsNothing() {
        val host = ScriptedPairingHost(qrSecret = ByteArray(32) { 0x5A })
        val pairing = link(phone(), host)
        pairing.start()
        pairing.confirm(accepted = true, secret = ByteArray(32) { 0x11 })

        assertEquals(FailureReason.PairingRefused("The code does not match this Mac"), pairing.failure())
        assertNull(pins.pin(ScriptedPairingHost.HOST_ID))
    }

    @Test
    fun aHostThatRefusesEndsTheHandshakeWithItsReasonAndPinsNothing() {
        val host = ScriptedPairingHost(refusal = "Another phone is pairing")
        val pairing = link(phone(), host)
        pairing.start()
        pairing.confirm(accepted = true)

        assertEquals(FailureReason.PairingRefused("Another phone is pairing"), pairing.failure())
        assertNull(pins.pin(ScriptedPairingHost.HOST_ID))
        assertNull(pairing.readyHello())
    }

    @Test
    fun aPinThatFailsToSaveDoesNotCountAsPaired() {
        val unsaved = FakePinStore().apply { writesSucceed = false }
        val host = ScriptedPairingHost()
        val pairing = link(phone(store = unsaved), host)
        pairing.start()
        pairing.confirm(accepted = true)

        assertEquals(FailureReason.PairingNotSaved, pairing.failure())
        assertNull(pairing.readyHello())
        assertNull(unsaved.pin(ScriptedPairingHost.HOST_ID))
    }

    @Test
    fun aHostWithAnotherIdEndsBeforeAnyKeyIsSent() {
        val host = ScriptedPairingHost(hostId = "OTHER-MAC")
        val pairing = link(phone(dialled = ScriptedPairingHost.HOST_ID), host)
        pairing.start()

        assertEquals(FailureReason.HostIdMismatch(ScriptedPairingHost.HOST_ID, "OTHER-MAC"), pairing.failure())
        assertTrue(MessageKind.PairCommit !in host.receivedKinds)
        assertNull(pins.pin("OTHER-MAC"))
    }

    @Test
    fun aPinnedHostIsReadyWithoutAnyCode() {
        val pinned = FakePinStore(mapOf(ScriptedPairingHost.HOST_ID to ScriptedPairingHost.HOST_KEY))
        val host = ScriptedPairingHost(alreadyPaired = true)
        val pairing = link(phone(dialled = ScriptedPairingHost.HOST_ID, store = pinned), host)
        pairing.start()

        assertEquals(ScriptedPairingHost.HOST_ID, pairing.readyHello()?.serverID)
        assertTrue(pairing.actions.none { it is ClientAction.ShowCode })
        assertTrue(!pairing.actions.contains(ClientAction.PinRecorded))
    }

    private companion object {
        const val CLIENT_ID = "11111111-2222-4333-8444-555555555555"
    }
}
