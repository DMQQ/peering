package pl.dmq.peering.session.agent

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.AgentRequest
import pl.dmq.peering.wire.AgentResumableSession
import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState
import pl.dmq.peering.wire.AgentStreamEvent
import pl.dmq.peering.wire.AgentStreamPayload
import pl.dmq.peering.wire.ServerHello

class AgentPauseAndImportTest {
    private val sent = mutableListOf<AgentRequest>()

    private fun info(id: String, state: AgentSessionState) = AgentSessionInfo(
        id = id,
        agentID = "claude",
        title = "Chat $id",
        directory = "/work",
        state = state,
        lastIndex = 0,
        createdAt = 0.0,
    )

    private fun chatWith(
        vararg payloads: AgentStreamPayload,
        state: AgentSessionState = AgentSessionState.IDLE,
    ): AgentChat {
        val chat = AgentChat { sent += it }
        chat.onEvent(AgentEvent.Snapshot(listOf(info("A", state))))
        payloads.forEachIndexed { index, payload ->
            chat.onEvent(AgentEvent.Stream("A", AgentStreamEvent(index.toLong() + 1, payload)))
        }
        sent.clear()
        return chat
    }

    @Test
    fun pauseIsSent() {
        chatWith().pause("A")
        assertEquals(listOf<AgentRequest>(AgentRequest.Pause("A")), sent)
    }

    @Test
    fun aChatIsPausedWhileTheHostsNoticeIsTheLastRow() {
        val chat = chatWith(AgentStreamPayload.UserPrompt("hi"), AgentStreamPayload.Notice(AgentPause.NOTICE))
        assertTrue(chat.state.value.selected!!.isPaused)
        chat.onEvent(AgentEvent.Stream("A", AgentStreamEvent(3, AgentStreamPayload.UserPrompt("back"))))
        assertFalse(chat.state.value.selected!!.isPaused)
    }

    @Test
    fun endingKeepsAQuietConversationAndClosesTheRest() {
        val talked = chatWith(AgentStreamPayload.UserPrompt("hi")).state.value.selected!!
        assertEquals(AgentEndAction.PAUSE, AgentEndAction.choose(talked))
        val empty = chatWith().state.value.selected!!
        assertEquals(AgentEndAction.CLOSE, AgentEndAction.choose(empty))
        val working = chatWith(AgentStreamPayload.UserPrompt("hi"), AgentStreamPayload.TurnStarted, state = AgentSessionState.WORKING).state.value.selected!!
        assertEquals(AgentEndAction.CLOSE, AgentEndAction.choose(working))
        val paused = chatWith(AgentStreamPayload.UserPrompt("hi"), AgentStreamPayload.Notice(AgentPause.NOTICE))
            .state.value.selected!!
        assertEquals(AgentEndAction.CLOSE, AgentEndAction.choose(paused))
    }

    @Test
    fun resumableSessionsAreListedDecodedAndContinued() {
        val chat = chatWith()
        assertNull(chat.resumable.value)
        chat.listResumable()
        val entry = json(
            """{"agentID":"claude","cliSessionID":"abc","directory":"/work","title":"Fix tests","modifiedAt":10.0,"mayBeOpenElsewhere":false}""",
        )
        chat.onEvent(AgentEvent.Resumable(listOf(entry, json("""{"bogus":1}"""))))
        val listed = chat.resumable.value!!
        assertEquals(listOf("Fix tests"), listed.map { it.title })
        chat.resume(listed.single())
        assertEquals(listOf(AgentRequest.ListResumable, AgentRequest.Resume("claude", "abc")), sent)
    }

    @Test
    fun aHostThatPredatesTheAgentListOffersClaudeAndCodex() {
        val hello = ServerHello(serverID = "s", hostName = "h", protocolVersion = 1, alreadyPaired = true)
        assertEquals(listOf("claude", "codex"), declaredAgents(hello))
        val declared = hello.copy(agentChatAgents = listOf("claude", "opencode"))
        assertEquals(listOf("claude", "opencode"), declaredAgents(declared))
    }

    private fun json(text: String): JsonElement = Json.parseToJsonElement(text)
}
