package pl.dmq.peering.session.agent.changes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.ports.KeyValueStore
import pl.dmq.peering.wire.AgentChangeKind
import pl.dmq.peering.wire.AgentChangedFile
import pl.dmq.peering.wire.AgentChangesReport

class ReviewQueueTest {
    private fun file(path: String, added: Int = 1, removed: Int = 0, diff: String? = "d") =
        AgentChangedFile(path, AgentChangeKind.MODIFIED, added, removed, diff)

    private fun source(chat: String, report: AgentChangesReport?, loading: Boolean = false) =
        ReviewSource(chat, "Chat $chat", "/p/$chat", report, loading)

    private fun report(vararg files: AgentChangedFile) = AgentChangesReport(isRepository = true, files = files.toList())

    @Test
    fun `a mark holds until the file changes again`() {
        val original = file("a.kt", added = 3)
        val marks = ReviewMarks().withReviewed(true, original, "C1")

        assertTrue(marks.isReviewed(original, "C1"))
        assertFalse(marks.isReviewed(original, "C2"))
        assertFalse(marks.isReviewed(file("a.kt", added = 4), "C1"))
        assertNotEquals(ReviewFingerprint.of(original), ReviewFingerprint.of(file("a.kt", diff = "other")))
    }

    @Test
    fun `unmarking removes the mark and an empty chat leaves no entry`() {
        val f = file("a.kt")
        val marks = ReviewMarks().withReviewed(true, f, "C1").withReviewed(false, f, "C1")

        assertEquals(ReviewMarks(), marks)
    }

    @Test
    fun `a real answer prunes outdated marks and a failed one keeps them`() {
        val f = file("a.kt")
        val marks = ReviewMarks().withReviewed(true, f, "C1")

        assertEquals(marks, marks.pruned("C1", AgentChangesReport.failure("offline")))
        assertEquals(marks, marks.pruned("C1", report(f)))
        assertEquals(ReviewMarks(), marks.pruned("C1", report(file("a.kt", added = 9))))
        assertEquals(ReviewMarks(), marks.pruned("C1", report()))
    }

    @Test
    fun `marks of chats that are gone are dropped`() {
        val marks = ReviewMarks().withReviewed(true, file("a"), "C1").withReviewed(true, file("b"), "C2")

        assertEquals(ReviewMarks().withReviewed(true, file("b"), "C2"), marks.retaining(setOf("C2")))
    }

    @Test
    fun `marks survive the store and an unreadable value reads as none`() {
        val values = HashMap<String, String>()
        val store = ReviewMarkStore(object : KeyValueStore {
            override fun read(key: String) = values[key]
            override fun write(key: String, value: String) { values[key] = value }
        })
        val marks = ReviewMarks().withReviewed(true, file("a.kt"), "C1")

        store.save(marks)
        assertEquals(marks, store.load())

        values["agent_review_marks"] = "not json"
        assertEquals(ReviewMarks(), store.load())
    }

    @Test
    fun `only unreviewed files in a current answer count as pending`() {
        val seen = file("a.kt", added = 2, removed = 1)
        val marks = ReviewMarks().withReviewed(true, seen, "C1")
        val queue = ReviewQueue.of(
            listOf(
                source("C1", report(seen, file("b.kt", added = 5, removed = 2))),
                source("C2", AgentChangesReport(isRepository = false, message = "no git")),
                source("C3", null, loading = true),
            ),
            marks,
        )

        assertEquals(1, queue.pendingFileCount)
        assertEquals(1, queue.pendingChatCount)
        assertEquals(5, queue.added)
        assertEquals(2, queue.removed)
        assertEquals(listOf("C1", "C3"), queue.visible.map { it.chatId })
        assertEquals(listOf("a.kt", "b.kt"), queue.groups[0].files.map { it.path })
    }

    @Test
    fun `the card holds its place while an answer is awaited and nothing is pending`() {
        assertTrue(ReviewQueue.of(listOf(source("C1", null, loading = true)), ReviewMarks()).checking)
        assertFalse(ReviewQueue.of(listOf(source("C1", report(file("a")))), ReviewMarks()).checking)
        assertFalse(ReviewQueue.of(listOf(source("C1", report())), ReviewMarks()).checking)
    }

    @Test
    fun `chats are asked again after thirty seconds, or three after a finished turn`() {
        val policy = ReviewRefreshPolicy()

        assertEquals(listOf("A", "B"), policy.chatsToAsk(listOf("A", "B"), ReviewRefreshPolicy.Reason.HUB_APPEARED, 0))
        assertEquals(emptyList<String>(), policy.chatsToAsk(listOf("A"), ReviewRefreshPolicy.Reason.HUB_APPEARED, 29_000))
        assertEquals(listOf("A"), policy.chatsToAsk(listOf("A"), ReviewRefreshPolicy.Reason.TURN_FINISHED, 32_000))
        assertEquals(emptyList<String>(), policy.chatsToAsk(listOf("A"), ReviewRefreshPolicy.Reason.TURN_FINISHED, 33_000))
        policy.forgetExcept(setOf("B"))
        assertEquals(listOf("A"), policy.chatsToAsk(listOf("A"), ReviewRefreshPolicy.Reason.HUB_APPEARED, 33_001))
    }
}
