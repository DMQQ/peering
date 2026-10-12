package pl.dmq.peering.session.agent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.AgentRequest
import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState

class AgentRenameTest {
    private val sent = mutableListOf<AgentRequest>()

    private fun info(title: String) =
        AgentSessionInfo("A", "claude", title, "/work", AgentSessionState.IDLE, 0L, createdAt = 0.0)

    private fun chat(): AgentChat {
        val chat = AgentChat(AgentCapabilities(chat = true)) { sent += it }
        chat.onEvent(AgentEvent.Snapshot(listOf(info("Fix the build"))))
        sent.clear()
        return chat
    }

    @Test
    fun aNameTypedOntoAChatReplacesTheComputersTitle() {
        val chat = chat()
        chat.rename("A", "  Release prep ")
        assertEquals("Release prep", chat.state.value.session("A")!!.title)
        assertEquals("Fix the build", chat.state.value.session("A")!!.info.title)
    }

    @Test
    fun theNameSurvivesTheComputersNextSnapshot() {
        val chat = chat()
        chat.rename("A", "Release prep")
        chat.onEvent(AgentEvent.Snapshot(listOf(info("Fix the build and more"))))
        assertEquals("Release prep", chat.state.value.session("A")!!.title)
    }

    @Test
    fun aBlankNameOrAnUnknownChatChangesNothing() {
        val chat = chat()
        chat.rename("A", "   ")
        chat.rename("Z", "Ghost")
        assertEquals("Fix the build", chat.state.value.session("A")!!.title)
        assertEquals(1, chat.state.value.sessions.size)
    }

    @Test
    fun renamingSendsNothingToTheComputer() {
        chat().rename("A", "Release prep")
        assertTrue(sent.isEmpty())
    }

    @Test
    fun noNameIsKeptWhenTheComputerNeverDeclaredChat() {
        val chat = AgentChat(AgentCapabilities(chat = false)) { sent += it }
        chat.onEvent(AgentEvent.Snapshot(listOf(info("Fix the build"))))
        chat.rename("A", "Release prep")
        assertEquals("Fix the build", chat.state.value.session("A")!!.title)
    }
}
