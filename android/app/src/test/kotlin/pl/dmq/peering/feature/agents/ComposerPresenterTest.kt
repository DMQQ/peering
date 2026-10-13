package pl.dmq.peering.feature.agents

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.agent.AgentChatSession
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.session.agent.ComposerDraft
import pl.dmq.peering.session.agent.ComposerDrafts
import pl.dmq.peering.wire.AgentPermissionMode
import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState

class ComposerPresenterTest {
    private fun session(
        id: String,
        state: AgentSessionState = AgentSessionState.IDLE,
        modes: List<AgentPermissionMode>? = null,
        current: AgentPermissionMode? = null,
        models: List<String>? = null,
        model: String? = null,
    ) = AgentChatSession(
        info = AgentSessionInfo(
            id = id, agentID = "claude", title = "t", directory = "/d", state = state, lastIndex = 0, createdAt = 0.0,
            model = model, permissionMode = current, permissionModes = modes, modelChoices = models,
        ),
    )

    private class Harness(
        chats: AgentChatState,
        drafts: ComposerDrafts = ComposerDrafts(),
        modelPicker: Boolean = true,
    ) {
        val port = FakeAgentsPort(chats)
        val store = FakeComposerDraftStore(drafts)
        val presenter = ComposerPresenter(
            port = port,
            store = store,
            chats = port.chats,
            modelPickerSupported = modelPicker,
            scope = CoroutineScope(UnconfinedTestDispatcher()),
        )
    }

    private fun chats(vararg sessions: AgentChatSession, selected: String? = sessions.firstOrNull()?.id) =
        AgentChatState(sessions = sessions.toList(), selectedSessionID = selected)

    @Test
    fun anIdleChatWithAnEmptyBoxCannotSend() = runTest {
        val ui = Harness(chats(session("S1"))).presenter.ui.value
        assertEquals(ComposerAction.SEND, ui.action)
        assertFalse(ui.actionEnabled)
    }

    @Test
    fun typingEnablesSendAndSavesTheDraftAgainstTheChat() = runTest {
        val harness = Harness(chats(session("S1")))
        harness.presenter.onTextChanged("hello")
        assertTrue(harness.presenter.ui.value.actionEnabled)
        assertEquals("hello", harness.store.current().draftFor("S1").text)
    }

    @Test
    fun sendingPassesTheAttachmentsFirstAndClearsTheDraft() = runTest {
        val harness = Harness(chats(session("S1")))
        harness.presenter.attach("/Users/me/app/log.txt")
        harness.presenter.onTextChanged("why does this fail")
        harness.presenter.send()
        assertEquals(listOf("prompt:S1:@/Users/me/app/log.txt why does this fail"), harness.port.calls)
        assertEquals("", harness.presenter.ui.value.text)
        assertTrue(harness.store.current().draftFor("S1").isEmpty)
    }

    @Test
    fun aWorkingChatQueuesATypedMessageAndStopsWhenTheBoxIsEmpty() = runTest {
        val harness = Harness(chats(session("S1", state = AgentSessionState.WORKING)))
        assertEquals(ComposerAction.STOP, harness.presenter.ui.value.action)
        harness.presenter.stop()
        assertEquals(listOf("interrupt:S1"), harness.port.calls)

        harness.presenter.onTextChanged("and also this")
        assertEquals(ComposerAction.QUEUE, harness.presenter.ui.value.action)
        harness.presenter.send()
        assertEquals("prompt:S1:and also this", harness.port.calls.last())
    }

    @Test
    fun stopIsNotSentWhileTheButtonIsShowingSend() = runTest {
        val harness = Harness(chats(session("S1")))
        harness.presenter.stop()
        assertTrue(harness.port.calls.isEmpty())
    }

    @Test
    fun awaitingApprovalCountsAsWorkingSoAMessageQueues() = runTest {
        val harness = Harness(chats(session("S1", state = AgentSessionState.AWAITING_APPROVAL)))
        harness.presenter.onTextChanged("x")
        assertEquals(ComposerAction.QUEUE, harness.presenter.ui.value.action)
    }

    @Test
    fun eachChatKeepsItsOwnDraftWhenTheSelectionMoves() = runTest {
        val port = FakeAgentsPort(chats(session("S1"), session("S2")))
        val store = FakeComposerDraftStore()
        val presenter = ComposerPresenter(port, store, port.chats, modelPickerSupported = false, scope = CoroutineScope(UnconfinedTestDispatcher()))
        presenter.onTextChanged("for one")
        port.chatState.value = port.chatState.value.copy(selectedSessionID = "S2")
        assertEquals("", presenter.ui.value.text)
        presenter.onTextChanged("for two")
        port.chatState.value = port.chatState.value.copy(selectedSessionID = "S1")
        assertEquals("for one", presenter.ui.value.text)
    }

    @Test
    fun aDraftSavedBeforeTheLaunchIsShownAgain() = runTest {
        val saved = ComposerDrafts(mapOf("S1" to ComposerDraft(text = "unfinished")))
        assertEquals("unfinished", Harness(chats(session("S1")), drafts = saved).presenter.ui.value.text)
    }

    @Test
    fun noSelectedChatMeansNothingCanBeSent() = runTest {
        val harness = Harness(AgentChatState(sessions = listOf(session("S1"))))
        harness.presenter.onTextChanged("lost")
        harness.presenter.send()
        assertTrue(harness.port.calls.isEmpty())
        assertFalse(harness.presenter.ui.value.actionEnabled)
    }

    @Test
    fun permissionMenuOffersOnlyTheModesTheSessionReports() = runTest {
        val harness = Harness(chats(session("S1", modes = listOf(AgentPermissionMode.MANUAL, AgentPermissionMode.PLAN), current = AgentPermissionMode.PLAN)))
        assertEquals(listOf(AgentPermissionMode.MANUAL, AgentPermissionMode.PLAN), harness.presenter.ui.value.permissionModes)
        assertEquals(AgentPermissionMode.PLAN, harness.presenter.ui.value.permissionMode)
        harness.presenter.setPermissionMode(AgentPermissionMode.AUTO)
        assertTrue(harness.port.calls.isEmpty())
        harness.presenter.setPermissionMode(AgentPermissionMode.MANUAL)
        assertEquals(listOf("mode:S1:MANUAL"), harness.port.calls)
    }

    @Test
    fun aSessionThatReportsNoModesShowsNoPermissionMenu() = runTest {
        assertTrue(Harness(chats(session("S1"))).presenter.ui.value.permissionModes.isEmpty())
    }

    @Test
    fun modelChoicesAreShownOnlyWhenTheMacDeclaresThePicker() = runTest {
        val models = chats(session("S1", models = listOf("opus", "sonnet")))
        assertEquals(listOf("opus", "sonnet"), Harness(models).presenter.ui.value.modelChoices)
        assertTrue(Harness(models, modelPicker = false).presenter.ui.value.modelChoices.isEmpty())
    }

    @Test
    fun aModelOutsideTheChoicesIsNotSentButTheDefaultAlwaysIs() = runTest {
        val harness = Harness(chats(session("S1", models = listOf("opus"))))
        harness.presenter.setModel("haiku")
        harness.presenter.setModel("opus")
        harness.presenter.setModel(null)
        assertEquals(listOf("model:S1:opus", "model:S1:null"), harness.port.calls)
    }

    @Test
    fun noModelIsSentWhenThePickerIsNotDeclared() = runTest {
        val harness = Harness(chats(session("S1", models = listOf("opus"))), modelPicker = false)
        harness.presenter.setModel(null)
        assertTrue(harness.port.calls.isEmpty())
    }

    @Test
    fun saveRunsOnEveryChangeToTheDraft() = runTest {
        val harness = Harness(chats(session("S1")))
        harness.presenter.onTextChanged("a")
        harness.presenter.onTextChanged("ab")
        assertEquals(2, harness.store.saves)
    }

    @Test
    fun detachRemovesTheChosenAttachment() = runTest {
        val harness = Harness(chats(session("S1")))
        harness.presenter.attach("/a")
        harness.presenter.attach("/b")
        harness.presenter.detach(0)
        assertEquals(listOf("/b"), harness.presenter.ui.value.attachedPaths)
    }

    @Test
    fun aSessionStateChangeReflectsOnTheButtonWithoutAnyInput() = runTest {
        val port = FakeAgentsPort(chats(session("S1", state = AgentSessionState.WORKING)))
        val presenter = ComposerPresenter(port, FakeComposerDraftStore(), port.chats, true, CoroutineScope(UnconfinedTestDispatcher()))
        port.chatState.value = chats(session("S1", state = AgentSessionState.IDLE))
        assertEquals(ComposerAction.SEND, presenter.ui.value.action)
    }
}
