package pl.dmq.peering.feature.pairing

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.session.connection.FailureReason
import pl.dmq.peering.wire.MessageKind

class PairingMessageMappingTest {
    @Test
    fun everyFailureReasonHasItsOwnMessage() {
        assertEquals(
            PairingMessage.UnexpectedFrame,
            FailureReason.UnexpectedFrame(MessageKind.entries.first(), "pair").toPairingMessage(),
        )
        assertEquals(PairingMessage.Malformed, FailureReason.MalformedMessage(MessageKind.entries.first()).toPairingMessage())
        assertEquals(PairingMessage.ProtocolMismatch, FailureReason.ProtocolMismatch(19, 20).toPairingMessage())
        assertEquals(PairingMessage.HostIdMismatch, FailureReason.HostIdMismatch("A", "B").toPairingMessage())
        assertEquals(PairingMessage.PinMismatch, FailureReason.PinMismatch("A").toPairingMessage())
        assertEquals(PairingMessage.NoPinOnFile, FailureReason.NoPinOnFile("A").toPairingMessage())
        assertEquals(PairingMessage.CommitmentMismatch, FailureReason.CommitmentMismatch.toPairingMessage())
        assertEquals(PairingMessage.Refused(null), FailureReason.PairingRefused(null).toPairingMessage())
        assertEquals(PairingMessage.Declined, FailureReason.PairingDeclined.toPairingMessage())
        assertEquals(PairingMessage.NotSaved, FailureReason.PairingNotSaved.toPairingMessage())
    }

    @Test
    fun aRefusalKeepsTheHostsExplanation() {
        assertEquals(
            PairingMessage.Refused("Already pairing"),
            FailureReason.PairingRefused("Already pairing").toPairingMessage(),
        )
    }
}
