package pl.dmq.peering.feature.agents

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.session.agent.AgentChatSession
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState

class RenamePresenterTest {
    private val session = AgentChatSession(
        info = AgentSessionInfo("A", "codex", "Fix", "/work", AgentSessionState.IDLE, 0L, createdAt = 0.0),
        renamedTo = "Release prep",
    )
    private val port = FakeAgentsPort(AgentChatState(sessions = listOf(session), selectedSessionID = "A"))
    private val scope = CoroutineScope(UnconfinedTestDispatcher())

    @Test
    fun theChatHeaderShowsTheNameThePhoneGaveIt() {
        assertEquals("Release prep", ChatPresenter(port, scope).ui.value.title)
    }

    @Test
    fun renamingFromTheChatNamesTheSelectedChat() {
        ChatPresenter(port, scope).rename("Shipping")
        assertEquals(listOf("rename:A:Shipping"), port.calls)
    }
}
