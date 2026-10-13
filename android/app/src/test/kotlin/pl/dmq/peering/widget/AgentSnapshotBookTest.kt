package pl.dmq.peering.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.agent.AgentChatSession
import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState

class AgentSnapshotBookTest {
    private fun entry(id: String, tone: AgentChatTone, at: Long = 0) = AgentChatEntry(id, "h", id, "f", tone, at)

    @Test
    fun waitingChatsComeFirstThenBusyThenNewest() {
        val book = AgentSnapshotBook()
        book.update("h", listOf(
            entry("done", AgentChatTone.FINISHED, 9),
            entry("old", AgentChatTone.WORKING, 1),
            entry("new", AgentChatTone.WORKING, 5),
            entry("ask", AgentChatTone.NEEDS_YOU, 0),
            entry("bad", AgentChatTone.FAILED, 3),
        ))
        assertEquals(listOf("ask", "new", "old", "bad", "done"), book.merged().map { it.id })
    }

    @Test
    fun aWriteThatOnlyMovedTheClockIsNotAChange() {
        val book = AgentSnapshotBook()
        assertTrue(book.update("h", listOf(entry("a", AgentChatTone.WORKING, 1))))
        assertFalse(book.update("h", listOf(entry("a", AgentChatTone.WORKING, 99))))
        assertTrue(book.update("h", listOf(entry("a", AgentChatTone.FINISHED, 99))))
    }

    @Test
    fun anEmptyListForAnUnknownComputerIsNotAChange() {
        assertFalse(AgentSnapshotBook().update("h", emptyList()))
    }

    @Test
    fun pruneDropsComputersThatAreNoLongerOpen() {
        val book = AgentSnapshotBook()
        book.update("h1", listOf(entry("a", AgentChatTone.WORKING)))
        book.update("h2", listOf(entry("b", AgentChatTone.WORKING)))
        assertTrue(book.prune(setOf("h2")))
        assertFalse(book.prune(setOf("h2")))
        assertEquals(listOf("b"), book.merged().map { it.id })
    }

    private fun session(state: AgentSessionState, failure: String? = null, directory: String = "/Users/me/app/") = AgentChatSession(
        info = AgentSessionInfo(
            id = "S", agentID = "claude", title = "Title", directory = directory,
            state = state, lastIndex = 0, createdAt = 0.0,
        ),
        failure = failure,
    )

    @Test
    fun sessionStatesMapToTheTonesTheIPhoneUses() {
        fun tone(state: AgentSessionState, failure: String? = null) =
            AgentChatEntries.from("h", listOf(session(state, failure)), 7).single().tone
        assertEquals(AgentChatTone.NEEDS_YOU, tone(AgentSessionState.AWAITING_APPROVAL))
        assertEquals(AgentChatTone.WORKING, tone(AgentSessionState.WORKING))
        assertEquals(AgentChatTone.FINISHED, tone(AgentSessionState.IDLE))
        assertEquals(AgentChatTone.FINISHED, tone(AgentSessionState.EXITED))
        assertEquals(AgentChatTone.FAILED, tone(AgentSessionState.FAILED))
        assertEquals(AgentChatTone.FAILED, tone(AgentSessionState.IDLE, failure = "boom"))
    }

    @Test
    fun theFolderIsTheLastPathComponent() {
        val entry = AgentChatEntries.from("h", listOf(session(AgentSessionState.IDLE)), 7).single()
        assertEquals("app", entry.folder)
        assertEquals("h", entry.hostId)
        assertEquals(7L, entry.updatedAtSeconds)
    }

    @Test
    fun aListIsStaleOnlyWhenItHasChatsAndIsOld() {
        val chats = listOf(entry("a", AgentChatTone.WORKING))
        assertFalse(AgentsSnapshot(chats, publishedAtSeconds = 100).isStale(100 + AgentsSnapshot.STALE_AFTER_SECONDS))
        assertTrue(AgentsSnapshot(chats, publishedAtSeconds = 100).isStale(101 + AgentsSnapshot.STALE_AFTER_SECONDS))
        assertFalse(AgentsSnapshot(emptyList(), publishedAtSeconds = 0).isStale(1_000_000))
    }

    @Test
    fun presenceIsConnectedThenOnlineThenOffline() {
        val snapshot = QuickConnectSnapshot(
            computers = listOf(KnownComputer("a", "A"), KnownComputer("b", "B"), KnownComputer("c", "C")),
            connectedId = "a",
            onlineIds = setOf("b"),
        )
        assertEquals(ComputerPresence.CONNECTED, snapshot.presence("a"))
        assertEquals(ComputerPresence.ONLINE, snapshot.presence("b"))
        assertEquals(ComputerPresence.OFFLINE, snapshot.presence("c"))
        assertEquals("A", snapshot.headline?.name)
    }
}
