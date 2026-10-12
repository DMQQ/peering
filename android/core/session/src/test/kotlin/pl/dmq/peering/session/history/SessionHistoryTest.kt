package pl.dmq.peering.session.history

import kotlinx.serialization.SerializationException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.history.SessionRecord.EndReason
import pl.dmq.peering.session.history.SessionRecord.Path

class SessionHistoryTest {
    private val history = SessionHistory()

    @Test
    fun aStartedSessionIsRecordedAsOpenAndNewestFirst() {
        val first = history.begin("host-1", "Studio", Path.LAN, startedAt = 1_000)
        val second = history.begin("host-2", "Office", Path.RELAY, startedAt = 2_000)

        assertEquals(listOf(second, first), history.records.map { it.id })
        val newest = history.records.first()
        assertEquals("host-2", newest.hostId)
        assertEquals(Path.RELAY, newest.path)
        assertNull(newest.endedAt)
        assertNull(newest.reason)
    }

    @Test
    fun endingASessionClosesItWithItsReason() {
        val id = history.begin("host-1", "Studio", Path.RELAY, startedAt = 1_000)

        assertTrue(history.end(id, endedAt = 61_000, reason = EndReason.USER_ENDED))

        val record = history.records.single()
        assertEquals(61_000L, record.endedAt)
        assertEquals(EndReason.USER_ENDED, record.reason)
    }

    @Test
    fun aSessionCannotBeClosedTwice() {
        val id = history.begin("host-1", "Studio", Path.LAN, startedAt = 1_000)
        history.end(id, endedAt = 2_000, reason = EndReason.CONNECTION_LOST)

        assertFalse(history.end(id, endedAt = 3_000, reason = EndReason.USER_ENDED))
        assertEquals(EndReason.CONNECTION_LOST, history.records.single().reason)
    }

    @Test
    fun anEndBeforeTheStartIsClampedToTheStart() {
        val id = history.begin("host-1", "Studio", Path.LAN, startedAt = 5_000)

        history.end(id, endedAt = 4_000, reason = EndReason.FAILED)

        assertEquals(5_000L, history.records.single().endedAt)
    }

    @Test
    fun theHistoryKeepsFiftyNewestRecords() {
        val ids = (1..55).map { history.begin("host-$it", "Mac $it", Path.LAN, startedAt = it.toLong()) }

        assertEquals(SessionHistory.DEFAULT_LIMIT, history.records.size)
        assertEquals(ids.last(), history.records.first().id)
        assertEquals(ids[5], history.records.last().id)
        assertFalse(history.end(ids.first(), endedAt = 100, reason = EndReason.USER_ENDED))
    }

    @Test
    fun aHistorySurvivesARoundTripAndKeepsCountingIds() {
        val closed = history.begin("host-1", "Studio", Path.DIRECT, startedAt = 1_000)
        history.end(closed, endedAt = 9_000, reason = EndReason.HOST_STOPPED)
        history.begin("host-2", "Office", Path.RELAY, startedAt = 10_000)

        val restored = SessionHistory.fromJson(history.toJson())

        assertEquals(history.records, restored.records)
        val next = restored.begin("host-3", "Den", Path.LAN, startedAt = 20_000)
        assertEquals(history.records.maxOf { it.id } + 1, next)
    }

    @Test
    fun theJsonUsesLowercasePathsAndIgnoresUnknownKeys() {
        val text = """[{"id":7,"hostId":"h","hostName":"Mac","startedAt":1,"path":"relay","futureField":true}]"""

        val restored = SessionHistory.fromJson(text)

        val record = restored.records.single()
        assertEquals(Path.RELAY, record.path)
        assertNull(record.endedAt)
        assertTrue(restored.toJson().contains("\"path\":\"relay\""))
    }

    @Test
    fun endingASessionStoresItsBytesAndLogAcrossARoundTrip() {
        val id = history.begin("host-1", "Studio", Path.RELAY, startedAt = 1_000)
        history.end(id, endedAt = 2_000, reason = EndReason.USER_ENDED, bytesReceived = 5_000, bytesSent = 300, logs = listOf("+0s up"))

        val restored = SessionHistory.fromJson(history.toJson()).records.single()

        assertEquals(5_000L, restored.bytesReceived)
        assertEquals(300L, restored.bytesSent)
        assertEquals(listOf("+0s up"), restored.logs)
    }

    @Test
    fun aHistoryStoredBeforeBytesWereCountedStillLoads() {
        val old = """[{"id":1,"hostId":"h","hostName":"Studio","startedAt":1000,"endedAt":2000,"path":"lan","reason":"userEnded"}]"""

        val record = SessionHistory.fromJson(old).records.single()

        assertEquals(0L, record.bytesReceived)
        assertTrue(record.logs.isEmpty())
    }

    @Test(expected = SerializationException::class)
    fun aMalformedHistoryIsRefusedRatherThanReadAsEmpty() {
        SessionHistory.fromJson("{not a list")
    }
}
