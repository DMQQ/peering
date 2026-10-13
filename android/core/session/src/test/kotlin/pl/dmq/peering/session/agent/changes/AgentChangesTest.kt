package pl.dmq.peering.session.agent.changes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.agent.AgentCapabilities
import pl.dmq.peering.session.agent.AgentChat
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.AgentGitOperation
import pl.dmq.peering.wire.AgentRequest
import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState

class AgentChangesTest {
    private val sent = mutableListOf<AgentRequest>()
    private val id = "A"

    private fun chat(chat: Boolean = true) = AgentChat(AgentCapabilities(chat = chat)) { sent += it }

    private fun changes(json: String) = AgentEvent.parse("""{"changes":{"sessionID":"$id","report":$json}}""")

    private fun gitResult(operation: String, ok: Boolean) =
        AgentEvent.parse("""{"gitResult":{"sessionID":"$id","result":{"operation":"$operation","succeeded":$ok,"message":"m"}}}""")

    @Test
    fun askingForChangesMarksTheChatLoadingUntilTheReportArrives() {
        val chat = chat()
        chat.loadChanges(id)
        assertEquals(listOf<AgentRequest>(AgentRequest.Changes(id)), sent)
        assertTrue(chat.changes.value.getValue(id).loading)
        chat.onEvent(changes("""{"isRepository":true,"files":[],"paths":[],"truncated":false}"""))
        val state = chat.changes.value.getValue(id)
        assertFalse(state.loading)
        assertNotNull(state.report)
    }

    @Test
    fun nothingIsSentToAComputerThatDidNotDeclareChat() {
        val chat = chat(chat = false)
        chat.loadChanges(id)
        chat.commitChanges(id, listOf("a"), "m")
        chat.pushChanges(id)
        assertTrue(sent.isEmpty())
        assertTrue(chat.changes.value.isEmpty())
    }

    @Test
    fun onlyOneCommitOrPushRunsAtATime() {
        val chat = chat()
        chat.commitChanges(id, listOf("a.txt"), "Add a.txt")
        chat.pushChanges(id)
        chat.commitChanges(id, listOf("b.txt"), "Add b.txt")
        assertEquals(listOf<AgentRequest>(AgentRequest.Commit(id, listOf("a.txt"), "Add a.txt")), sent)
        assertEquals(AgentGitOperation.COMMIT, chat.changes.value.getValue(id).gitBusy)
        chat.onEvent(gitResult("commit", ok = true))
        assertNull(chat.changes.value.getValue(id).gitBusy)
        chat.pushChanges(id)
        assertEquals(AgentRequest.Push(id), sent.last())
    }

    @Test
    fun aRefusedCommitBecomesAFailedResultInsteadOfAChatFailure() {
        val chat = chat()
        chat.onEvent(AgentEvent.Snapshot(listOf(AgentSessionInfo(id, "claude", "t", "/", AgentSessionState.IDLE, 0L, createdAt = 0.0))))
        chat.commitChanges(id, listOf("a"), "m")
        chat.onEvent(AgentEvent.Failed(id, "Nothing to commit"))
        val state = chat.changes.value.getValue(id)
        assertNull(state.gitBusy)
        assertFalse(state.gitResult!!.succeeded)
        assertEquals("Nothing to commit", state.gitResult!!.message)
        assertNull(chat.state.value.session(id)!!.failure)
    }

    @Test
    fun aRefusedFirstLoadLeavesAFailureReportInsteadOfASpinner() {
        val chat = chat()
        chat.loadChanges(id)
        chat.onEvent(AgentEvent.Failed(id, "That chat is gone"))
        val state = chat.changes.value.getValue(id)
        assertFalse(state.loading)
        assertFalse(state.report!!.isRepository)
        assertEquals("That chat is gone", state.report!!.message)
    }

    @Test
    fun aFailureWithNothingWaitingIsLeftForTheChat() {
        val chat = chat()
        chat.onEvent(AgentEvent.Failed(null, "No computer answered"))
        assertEquals("No computer answered", chat.state.value.failure)
        assertTrue(chat.changes.value.isEmpty())
    }

    @Test
    fun aClosedChatForgetsItsChanges() {
        val chat = chat()
        chat.loadChanges(id)
        chat.onEvent(AgentEvent.Closed(id))
        assertTrue(chat.changes.value.isEmpty())
    }

    @Test
    fun anUnreadableReportKeepsTheOneAlreadyHeld() {
        val chat = chat()
        chat.onEvent(changes("""{"isRepository":true,"files":[],"paths":["x"],"truncated":false}"""))
        chat.onEvent(changes("""{"files":7}"""))
        assertEquals(listOf("x"), chat.changes.value.getValue(id).report!!.paths)
    }
}
