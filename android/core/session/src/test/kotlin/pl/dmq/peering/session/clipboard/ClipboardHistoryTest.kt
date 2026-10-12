package pl.dmq.peering.session.clipboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.clipboard.ClipboardDirection.FROM_COMPUTER
import pl.dmq.peering.session.clipboard.ClipboardDirection.TO_COMPUTER
import pl.dmq.peering.session.ports.KeyValueStore
import pl.dmq.peering.wire.MAX_CLIPBOARD_IMAGE_BYTES

class ClipboardHistoryTest {
    private var now = 1_000L
    private val store = MemoryStore()

    private fun history(limit: Int = 25, imageBudget: Int = 1_000, kept: KeyValueStore? = null) =
        ClipboardHistory(kept, { now }, limit, imageBudget)

    private fun ClipboardHistory.texts() = entries.value.map { (it.content as ClipboardContent.Text).text }

    private fun text(value: String) = ClipboardContent.Text(value)

    private fun image(size: Int, fill: Byte = 1) = ClipboardContent.Image(ByteArray(size) { fill })

    @Test
    fun newestComesFirst() {
        val history = history()
        history.record(text("a"), FROM_COMPUTER)
        history.record(text("b"), TO_COMPUTER)

        assertEquals(listOf("b", "a"), history.texts())
    }

    @Test
    fun theLimitDropsTheOldest() {
        val history = history(limit = 3)
        listOf("a", "b", "c", "d").forEach { history.record(text(it), FROM_COMPUTER) }

        assertEquals(listOf("d", "c", "b"), history.texts())
    }

    @Test
    fun aRepeatMovesToTheTopWithTheNewTimeAndDirection() {
        val history = history()
        history.record(text("a"), FROM_COMPUTER)
        history.record(text("b"), FROM_COMPUTER)
        now = 2_000L
        history.record(text("a"), TO_COMPUTER)

        val top = history.entries.value.first()
        assertEquals(listOf("a", "b"), history.texts())
        assertEquals(2_000L, top.atMillis)
        assertEquals(TO_COMPUTER, top.direction)
    }

    @Test
    fun theSamePictureIsKeptOnce() {
        val history = history()
        history.record(image(10), FROM_COMPUTER)
        history.record(image(10), TO_COMPUTER)
        history.record(image(10, fill = 2), TO_COMPUTER)

        assertEquals(2, history.entries.value.size)
    }

    @Test
    fun blankTextAndOversizedTextAreNotKept() {
        val history = history()
        history.record(text(" \n"), FROM_COMPUTER)
        history.record(text("a".repeat(ClipboardHistory.MAX_TEXT_BYTES + 1)), FROM_COMPUTER)
        history.record(text("a".repeat(ClipboardHistory.MAX_TEXT_BYTES)), FROM_COMPUTER)

        assertEquals(1, history.entries.value.size)
    }

    @Test
    fun aPictureOverTheSizeCapOrEmptyIsNotKept() {
        val history = history(imageBudget = Int.MAX_VALUE)
        history.record(image(MAX_CLIPBOARD_IMAGE_BYTES + 1), FROM_COMPUTER)
        history.record(image(0), FROM_COMPUTER)
        history.record(image(MAX_CLIPBOARD_IMAGE_BYTES), FROM_COMPUTER)

        assertEquals(1, history.entries.value.size)
    }

    @Test
    fun picturesBeyondTheBudgetDropOldestFirstAndNeverTheNewest() {
        val history = history(imageBudget = 100)
        history.record(image(60, 1), FROM_COMPUTER)
        history.record(text("t"), FROM_COMPUTER)
        history.record(image(60, 2), FROM_COMPUTER)

        val kept = history.entries.value.map { it.content }
        assertEquals(listOf(image(60, 2), text("t")), kept)
    }

    @Test
    fun removeAndClearForgetEntries() {
        val history = history()
        history.record(text("a"), FROM_COMPUTER)
        history.record(text("b"), FROM_COMPUTER)
        history.remove(history.entries.value.first().id)
        assertEquals(listOf("a"), history.texts())

        history.clear()
        assertTrue(history.entries.value.isEmpty())
    }

    @Test
    fun textSurvivesARelaunchAndPicturesDoNot() {
        val first = history(kept = store)
        first.record(text("a"), FROM_COMPUTER)
        first.record(image(10), FROM_COMPUTER)
        first.record(text("b"), TO_COMPUTER)

        val second = history(kept = store)

        assertEquals(listOf("b", "a"), second.texts())
        assertEquals(TO_COMPUTER, second.entries.value.first().direction)
    }

    @Test
    fun clearingIsPersisted() {
        val first = history(kept = store)
        first.record(text("a"), FROM_COMPUTER)
        first.clear()

        assertTrue(history(kept = store).entries.value.isEmpty())
    }

    @Test
    fun anUnreadableStoreStartsEmpty() {
        store.write("clipboard_history", "{nope")

        assertTrue(history(kept = store).entries.value.isEmpty())
    }

    private class MemoryStore : KeyValueStore {
        private val values = mutableMapOf<String, String>()

        override fun read(key: String): String? = values[key]

        override fun write(key: String, value: String) {
            values[key] = value
        }
    }
}
