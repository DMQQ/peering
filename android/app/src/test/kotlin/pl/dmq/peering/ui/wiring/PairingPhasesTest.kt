package pl.dmq.peering.ui.wiring

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.feature.pairing.PairingPhase
import pl.dmq.peering.session.connection.FailureReason
import pl.dmq.peering.session.controller.SessionFailure
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.session.history.SessionRecord

class PairingPhasesTest {
    @Test
    fun theSixDigitsWaitingForAnAnswerAreConfirming() {
        assertEquals(PairingPhase.Confirming("123456"), SessionPhase.ConfirmingPairing("123456").toPairingPhase())
    }

    @Test
    fun aSessionThatIsStillConnectingIsWaiting() {
        assertEquals(PairingPhase.Waiting, SessionPhase.Connecting(SessionRecord.Path.LAN).toPairingPhase())
        assertEquals(PairingPhase.Waiting, SessionPhase.Reconnecting(1).toPairingPhase())
        assertEquals(PairingPhase.Waiting, SessionPhase.Idle.toPairingPhase())
    }

    @Test
    fun aReadySessionIsADonePairing() {
        val ready = SessionPhase.Ready("Studio", emptySet(), SessionRecord.Path.LAN)

        assertEquals(PairingPhase.Done, ready.toPairingPhase())
    }

    @Test
    fun aHandshakeFailureKeepsItsOwnReason() {
        val reason = FailureReason.PinMismatch("host")
        val failed = SessionPhase.Failed(SessionFailure.Handshake(reason), canRetry = false)

        assertEquals(PairingPhase.Failed(reason), failed.toPairingPhase())
    }

    @Test
    fun aFailureOutsideTheHandshakeReadsAsTheMacNotBeingReached() {
        assertEquals(FailureReason.Unreachable, SessionFailure.Unreachable.toFailureReason())
        assertEquals(FailureReason.Unreachable, SessionFailure.HostNotFound.toFailureReason())
        assertEquals(FailureReason.Unreachable, SessionFailure.MalformedFrame.toFailureReason())
    }

    @Test
    fun theConnectedHostIsKnownOnlyWhileTheSessionIsOnIt() {
        assertEquals("host", connectedHostId(SessionPhase.Ready("Studio", emptySet(), SessionRecord.Path.RELAY), "host"))
        assertEquals("host", connectedHostId(SessionPhase.Reconnecting(2), "host"))
        assertEquals(null, connectedHostId(SessionPhase.Connecting(SessionRecord.Path.RELAY), "host"))
        assertEquals(null, connectedHostId(SessionPhase.Ended, "host"))
    }
}
