package pl.dmq.peering.feature.pairing

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.wire.PairingPayload

class PairingDigitsTest {
    @Test
    fun onlyDigitsAreKept() = assertEquals("0423", pairingDigits("04 2-3x"))

    @Test
    fun aPastedCodeIsCutToSixDigits() = assertEquals("042317", pairingDigits("0423179"))

    @Test
    fun aPastedPairingLinkGivesItsCode() = assertEquals("042317", pairingDigits(PairingPayload.codeLink("042317", ByteArray(16))))

    @Test
    fun nothingTypedStaysEmpty() = assertEquals("", pairingDigits("abc"))
}
