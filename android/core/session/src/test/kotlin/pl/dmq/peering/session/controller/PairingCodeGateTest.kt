package pl.dmq.peering.session.controller

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class PairingCodeGateTest {
    @Test
    fun theRightDigitsMatch() {
        assertEquals(CodeCheck.Match, PairingCodeGate("042317").check("042317"))
    }

    @Test
    fun leadingZerosAreSignificant() {
        assertEquals(CodeCheck.Mismatch, PairingCodeGate("042317").check("42317"))
    }

    @Test
    fun wrongDigitsCountUntilTheLimitThenDecline() {
        val gate = PairingCodeGate("042317", limit = 3)

        assertEquals(CodeCheck.Mismatch, gate.check("111111"))
        assertEquals(CodeCheck.Mismatch, gate.check("222222"))
        assertEquals(CodeCheck.TooManyAttempts, gate.check("333333"))
        assertEquals(3, gate.wrongAttempts)
    }

    @Test
    fun aRightCodeAfterWrongOnesStillMatches() {
        val gate = PairingCodeGate("042317", limit = 3)
        gate.check("111111")

        assertEquals(CodeCheck.Match, gate.check("042317"))
    }

    @Test
    fun itsTextNeverContainsTheCode() {
        assertFalse(PairingCodeGate("042317").toString().contains("042317"))
    }
}
