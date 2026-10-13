package pl.dmq.peering.feature.agents

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.feature.agents.review.ReviewInbox
import pl.dmq.peering.session.agent.AgentChatSession
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.session.agent.changes.AgentChangesState
import pl.dmq.peering.session.agent.changes.ReviewMarkStore
import pl.dmq.peering.session.ports.KeyValueStore
import pl.dmq.peering.wire.AgentChangeKind
import pl.dmq.peering.wire.AgentChangedFile
import pl.dmq.peering.wire.AgentChangesReport
import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState

class ReviewInboxTest {
    private class MapStore : KeyValueStore {
        val values = HashMap<String, String>()
        override fun read(key: String) = values[key]
        override fun write(key: String, value: String) { values[key] = value }
    }

    private fun chat(id: String, state: AgentSessionState = AgentSessionState.IDLE) = AgentChatSession(
        info = AgentSessionInfo(id = id, agentID = "claude", title = "T$id", directory = "/p/$id", state = state, lastIndex = 0, createdAt = 0.0),
    )

    private fun file(path: String) = AgentChangedFile(path, AgentChangeKind.MODIFIED, 2, 1, "diff")

    private class Rig(scope: CoroutineScope, chats: AgentChatState, val store: MapStore = MapStore()) {
        var now = 0L
        val port = FakeAgentsPort(chats)
        val inbox = ReviewInbox(port, ReviewMarkStore(store), scope) { now }
    }

    private fun TestScopeRig(scope: CoroutineScope, vararg chats: AgentChatSession) =
        Rig(scope, AgentChatState(sessions = chats.toList(), selectedSessionID = chats.firstOrNull()?.id))

    @Test
    fun `the hub asks for each chat once and again only after thirty seconds`() = runTest {
        val rig = TestScopeRig(CoroutineScope(UnconfinedTestDispatcher(testScheduler)), chat("A"), chat("B"))

        rig.inbox.onHubAppeared()
        rig.now = 10_000
        rig.inbox.onHubAppeared()
        assertEquals(listOf("changes:A", "changes:B"), rig.port.calls)

        rig.now = 31_000
        rig.inbox.onHubAppeared()
        assertEquals(4, rig.port.calls.size)
    }

    @Test
    fun `a chat whose turn just ended is asked about soon after`() = runTest {
        val rig = TestScopeRig(CoroutineScope(UnconfinedTestDispatcher(testScheduler)), chat("A", AgentSessionState.WORKING))
        rig.inbox.onHubAppeared()
        rig.now = 5_000

        rig.port.chatState.value = AgentChatState(sessions = listOf(chat("A", AgentSessionState.IDLE)), selectedSessionID = "A")

        assertEquals(listOf("changes:A", "changes:A"), rig.port.calls)
    }

    @Test
    fun `reviewed marks are kept across restarts and tie to the file as it was`() = runTest {
        val rig = TestScopeRig(CoroutineScope(UnconfinedTestDispatcher(testScheduler)), chat("A"))
        rig.port.changesState.value = mapOf("A" to AgentChangesState(report = AgentChangesReport(true, files = listOf(file("a.kt"), file("b.kt")))))
        assertEquals(2, rig.inbox.queue.value.pendingFileCount)

        rig.inbox.setReviewed("A", file("a.kt"), true)
        assertEquals(1, rig.inbox.queue.value.pendingFileCount)

        val reopened = Rig(CoroutineScope(UnconfinedTestDispatcher(testScheduler)), rig.port.chatState.value, rig.store)
        reopened.port.changesState.value = rig.port.changesState.value
        assertEquals(1, reopened.inbox.queue.value.pendingFileCount)
    }

    @Test
    fun `a file that changed again loses its mark`() = runTest {
        val rig = TestScopeRig(CoroutineScope(UnconfinedTestDispatcher(testScheduler)), chat("A"))
        rig.port.changesState.value = mapOf("A" to AgentChangesState(report = AgentChangesReport(true, files = listOf(file("a.kt")))))
        rig.inbox.setReviewed("A", file("a.kt"), true)
        assertEquals(0, rig.inbox.queue.value.pendingFileCount)

        val moved = AgentChangedFile("a.kt", AgentChangeKind.MODIFIED, 9, 1, "new diff")
        rig.port.changesState.value = mapOf("A" to AgentChangesState(report = AgentChangesReport(true, files = listOf(moved))))

        assertEquals(1, rig.inbox.queue.value.pendingFileCount)
    }

    @Test
    fun `an empty chat list does not forget the marks`() = runTest {
        val rig = TestScopeRig(CoroutineScope(UnconfinedTestDispatcher(testScheduler)), chat("A"))
        rig.port.changesState.value = mapOf("A" to AgentChangesState(report = AgentChangesReport(true, files = listOf(file("a.kt")))))
        rig.inbox.setReviewed("A", file("a.kt"), true)

        rig.port.chatState.value = AgentChatState()
        rig.port.chatState.value = AgentChatState(sessions = listOf(chat("A")), selectedSessionID = "A")

        assertTrue(rig.inbox.queue.value.groups.single().files.single().reviewed)
    }

    @Test
    fun `mark all reviews the pending files and a second time takes the marks off`() = runTest {
        val rig = TestScopeRig(CoroutineScope(UnconfinedTestDispatcher(testScheduler)), chat("A"))
        rig.port.changesState.value = mapOf("A" to AgentChangesState(report = AgentChangesReport(true, files = listOf(file("a.kt"), file("b.kt")))))

        rig.inbox.toggleAll(rig.inbox.queue.value.groups.single())
        assertEquals(0, rig.inbox.queue.value.pendingFileCount)

        rig.inbox.toggleAll(rig.inbox.queue.value.groups.single())
        assertEquals(2, rig.inbox.queue.value.pendingFileCount)
    }
}
