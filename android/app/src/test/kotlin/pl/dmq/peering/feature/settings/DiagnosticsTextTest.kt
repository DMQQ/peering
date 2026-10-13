package pl.dmq.peering.feature.settings

import org.junit.Assert.assertEquals
import org.junit.Test

class DiagnosticsTextTest {
    @Test
    fun theReportNamesTheVersionDeviceAndPlanOnSeparateLines() {
        val text = diagnosticsText("1.4", "15", "Pixel 9", "abc123", 2, allowsRelay = false, paidRelay = true)
        assertEquals(
            "Peering 1.4\nAndroid 15, Pixel 9\nDevice ID: abc123\nPaired computers: 2\nRelay connections: off\nPlan: paid",
            text,
        )
    }

    @Test
    fun aFreeDeviceWithRelayOnSaysSo() {
        val text = diagnosticsText("1.4", "15", "Pixel 9", "abc123", 0, allowsRelay = true, paidRelay = false)
        assertEquals(true, text.endsWith("Relay connections: allowed\nPlan: free"))
    }
}
