package pl.dmq.peering.feature.pairing

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingCodeScreenTest {
    @Test
    fun onlyAFinishedPairingKeepsItsConnectionOpen() {
        assertTrue(PairingCodeScreen.Done.keepsConnection)
        assertFalse(PairingCodeScreen.Connecting.keepsConnection)
        assertFalse(PairingCodeScreen.Waiting.keepsConnection)
        assertFalse(PairingCodeScreen.Cancelled.keepsConnection)
        assertFalse(PairingCodeScreen.EnteringCode(0, null).keepsConnection)
        assertFalse(PairingCodeScreen.Failed(PairingMessage.Unreachable).keepsConnection)
    }
}
