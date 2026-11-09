package pl.dmq.peering.session.agent

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.AgentPermissionMode
import pl.dmq.peering.wire.AgentRequest
import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState
import pl.dmq.peering.wire.RemoteDirectoryEntry

class AgentChatRequestsTest {
    private val sent = mutableListOf<AgentRequest>()

    private fun info(id: String) = AgentSessionInfo(
        id = id,
        agentID = "claude",
        title = "Chat $id",
        directory = "/work",
        state = AgentSessionState.IDLE,
        lastIndex = 0,
        createdAt = 0.0,
    )

    private fun chat() = AgentChat { sent += it }

    @Test
    fun modelAndPermissionRequestsAreSent() {
        val chat = chat()
        chat.setModel("A", null)
        chat.setPermissionMode("A", AgentPermissionMode.ACCEPT_EDITS)
        assertEquals(
            listOf<AgentRequest>(AgentRequest.SetModel("A", null), AgentRequest.SetPermissionMode("A", AgentPermissionMode.ACCEPT_EDITS)),
            sent,
        )
    }

    @Test
    fun browseIsSent() {
        chat().browse(null)
        assertEquals(listOf<AgentRequest>(AgentRequest.Browse(null)), sent)
    }

    @Test
    fun modelAndPermissionEventsAreAppliedToTheChatTheyName() {
        val chat = chat()
        chat.onEvent(AgentEvent.Snapshot(listOf(info("A"))))
        chat.onEvent(AgentEvent.ModelChanged("A", "opus"))
        chat.onEvent(AgentEvent.PermissionModeChanged("A", AgentPermissionMode.ACCEPT_EDITS))
        val session = chat.state.value.selected!!
        assertEquals("opus", session.info.model)
        assertEquals(AgentPermissionMode.ACCEPT_EDITS, session.info.permissionMode)
    }

    @Test
    fun folderEventsReachTheBrowseFlowAndNotTheChatState() = runTest {
        val chat = chat()
        val received = mutableListOf<AgentEvent>()
        val job = launch(StandardTestDispatcher(testScheduler), start = CoroutineStart.UNDISPATCHED) {
            chat.browseEvents.collect { received += it }
        }
        val listing = AgentEvent.Directory(
            "/work",
            listOf(RemoteDirectoryEntry("src", isDirectory = true, isSymlink = false, size = 0, permissions = "rwx")),
            truncated = false,
        )
        chat.onEvent(listing)
        chat.onEvent(AgentEvent.BrowseFailure("/nope", "Denied"))
        runCurrent()
        job.cancel()
        assertEquals(listOf<AgentEvent>(listing, AgentEvent.BrowseFailure("/nope", "Denied")), received)
        assertEquals(emptyList<AgentSessionInfo>(), chat.state.value.sessions.map { it.info })
    }
}
