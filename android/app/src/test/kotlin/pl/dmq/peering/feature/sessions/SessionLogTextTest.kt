package pl.dmq.peering.feature.sessions

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.history.SessionRecord

class SessionLogTextTest {
    private val record = SessionRecord(
        id = 1,
        hostId = "h",
        hostName = "Studio",
        startedAt = 0,
        endedAt = 75_000,
        path = SessionRecord.Path.RELAY,
        bytesReceived = 1_200_000,
        bytesSent = 4_000,
        logs = listOf("+0s control connection open over RELAY"),
    )

    @Test
    fun theTextCarriesTheRowsThenTheLog() {
        val lines = sessionLogText(record, "1.2.3", "Oct 12, 9:00 AM", nowMillis = 0).lines()

        assertEquals("Peering session · Studio", lines.first())
        assertTrue("Duration: 1m 15s" in lines)
        assertTrue("Received: 1.2 MB" in lines)
        assertTrue("Sent: 4 KB" in lines)
        assertEquals("+0s control connection open over RELAY", lines.last())
    }

    @Test
    fun aRecordWithoutALogSaysSo() {
        val text = sessionLogText(record.copy(logs = emptyList()), "1.2.3", "now", nowMillis = 0)

        assertTrue(text.endsWith("No diagnostic events were recorded for this session."))
    }
}
