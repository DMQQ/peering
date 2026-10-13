package pl.dmq.peering.feature.agents

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.agent.AgentChatSession
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.session.agent.DirectoryLister
import pl.dmq.peering.session.agent.SlashDetail
import pl.dmq.peering.session.agent.SlashKind
import pl.dmq.peering.session.agent.SlashSuggestion
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState
import pl.dmq.peering.wire.RemoteDirectoryEntry

class ComposerHintsTest {
    private class Harness(scope: CoroutineScope, agent: String = "claude") {
        val asked = mutableListOf<String>()
        val port = FakeAgentsPort(
            AgentChatState(
                sessions = listOf(
                    AgentChatSession(
                        info = AgentSessionInfo(
                            id = "S1", agentID = agent, title = "t", directory = "/Users/me/app", state = AgentSessionState.IDLE,
                            lastIndex = 0, createdAt = 0.0,
                        ),
                    ),
                ),
                selectedSessionID = "S1",
            ),
        )
        val composer = ComposerPresenter(port, FakeComposerDraftStore(), port.chats, modelPickerSupported = true, scope = scope)
        val lister = DirectoryLister({ asked += it }, scope, { 0L })
        val hints = ComposerHints(composer.ui, lister, composer.hintOffers, scope)
    }

    private fun harness(scope: CoroutineScope) = Harness(scope)

    private fun entries(vararg names: String) =
        AgentEvent.Directory("/x", names.map { RemoteDirectoryEntry(it, it.endsWith("/"), false, 0, "rw-") }, truncated = false)

    @Test
    fun `plain text has no hint`() = runTest {
        val h = harness(CoroutineScope(UnconfinedTestDispatcher(testScheduler)))
        h.composer.onTextChanged("hello there")

        assertEquals(ComposerHint.None, h.hints.hint.value)
        assertTrue(h.asked.isEmpty())
    }

    @Test
    fun `a slash offers the app commands and asks for the command folders`() = runTest {
        val h = harness(CoroutineScope(UnconfinedTestDispatcher(testScheduler)))
        h.composer.onTextChanged("/")

        val hint = h.hints.hint.value as ComposerHint.Slash
        assertEquals(listOf("model", "rename", "usage", "clear", "compact"), hint.items.map { it.name })
        assertEquals(listOf("/Users/me/app/.claude/commands"), h.asked)
    }

    @Test
    fun `a mention asks for its folder and fills in when it answers`() = runTest {
        val h = harness(CoroutineScope(UnconfinedTestDispatcher(testScheduler)))
        h.composer.onTextChanged("look at @sr")

        assertEquals(listOf("/Users/me/app"), h.asked)
        assertTrue((h.hints.hint.value as ComposerHint.Mention).loading)

        h.lister.onEvent(entries("src/", "README.md"))

        val hint = h.hints.hint.value as ComposerHint.Mention
        assertEquals(listOf("src/"), hint.matches.map { it.name })
    }

    @Test
    fun `picking a file command types it for the cli and an app command is handed to the screen`() = runTest {
        val h = harness(CoroutineScope(UnconfinedTestDispatcher(testScheduler)))
        val emitted = mutableListOf<String>()
        val job = launchCollect(h, emitted)

        h.composer.pickSlash(SlashSuggestion("deploy", SlashDetail.THIS_PROJECT, SlashKind.COMMAND))
        assertEquals("/deploy ", h.composer.ui.value.text)

        h.composer.pickSlash(SlashSuggestion("usage", SlashDetail.USAGE, SlashKind.APP))
        assertEquals("", h.composer.ui.value.text)
        assertEquals(listOf("usage"), emitted)
        job.cancel()
    }

    @Test
    fun `sending an app command typed in full runs it instead of messaging the agent`() = runTest {
        val h = harness(CoroutineScope(UnconfinedTestDispatcher(testScheduler)))
        val emitted = mutableListOf<String>()
        val job = launchCollect(h, emitted)

        h.composer.onTextChanged("/rename")
        h.composer.send()

        assertEquals(listOf("rename"), emitted)
        assertTrue(h.port.calls.none { it.startsWith("prompt") })
        job.cancel()
    }

    @Test
    fun `picking a folder mention keeps the mention open and a file ends it`() = runTest {
        val h = harness(CoroutineScope(UnconfinedTestDispatcher(testScheduler)))
        h.composer.onTextChanged("see @sr")
        val query = (h.hints.hint.value as ComposerHint.Mention).query

        h.composer.pickMention(query, "src", isFolder = true)
        assertEquals("see @src/", h.composer.ui.value.text)

        val deeper = (h.hints.hint.value as ComposerHint.Mention).query
        h.composer.pickMention(deeper, "src/Main.kt", isFolder = false)
        assertEquals("see @src/Main.kt ", h.composer.ui.value.text)
    }

    private fun TestScope.launchCollect(h: Harness, into: MutableList<String>) =
        launch(UnconfinedTestDispatcher(testScheduler)) { h.composer.appCommands.collect { into += it } }
}
