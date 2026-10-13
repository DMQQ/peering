package pl.dmq.peering.feature.scan

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.wire.PairingPayload

class ScanOutcomeTest {
    private val hostId = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"

    @Test
    fun aDeviceIdLinkFindsTheMac() {
        assertEquals(ScanOutcome.Used, hostIdScanOutcome(PairingPayload.hostLink(hostId)))
    }

    @Test
    fun aBareDeviceIdFindsTheMac() {
        assertEquals(ScanOutcome.Used, hostIdScanOutcome(hostId))
    }

    @Test
    fun aPairingCodeLinkIsNotAMacToFind() {
        assertEquals(ScanOutcome.NotAPairingCode, hostIdScanOutcome(PairingPayload.codeLink("418205")))
    }

    @Test
    fun someOtherCodeIsNotAPairingCode() {
        assertEquals(ScanOutcome.NotAPairingCode, hostIdScanOutcome("WIFI:S:office;T:WPA;P:secret;;"))
    }

    @Test
    fun theCodeOnScreenConfirms() {
        assertEquals(ScanOutcome.Used, pairingCodeScanOutcome(PairingPayload.codeLink("418205", byteArrayOf(1, 2)), "418205"))
    }

    @Test
    fun aDifferentCodeIsRefusedAsWrong() {
        assertEquals(ScanOutcome.WrongCode, pairingCodeScanOutcome(PairingPayload.codeLink("000111"), "418205"))
    }

    @Test
    fun aDeviceIdLinkIsNotAPairingCodeOnScreen() {
        assertEquals(ScanOutcome.NotAPairingCode, pairingCodeScanOutcome(PairingPayload.hostLink(hostId), "418205"))
    }
}
