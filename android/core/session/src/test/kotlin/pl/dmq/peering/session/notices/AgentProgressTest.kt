package pl.dmq.peering.session.notices

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.wire.AgentSessionState

class AgentProgressTest {
    private val progress = AgentProgress()

    private fun chat(state: AgentSessionState, loaded: Boolean = true, title: String = "Fix tests") =
        ChatView("c1", title, state, loaded, emptyList(), null)

    private fun inputs(vararg chats: ChatView, away: Boolean = true, enabled: Boolean = true) =
        NoticeInputs(away, enabled, "Studio Mac", "host1", chats.toList(), emptyList())

    private fun shown(stage: ProgressStage, title: String = "Fix tests") =
        ProgressAction.Show(ProgressNotice("c1", title, stage, "Studio Mac", "host1"))

    @Test
    fun aWorkingTurnIsShownOnceWhileAway() {
        assertEquals(listOf(shown(ProgressStage.WORKING)), progress.plan(inputs(chat(AgentSessionState.WORKING))))
        assertEquals(emptyList<ProgressAction>(), progress.plan(inputs(chat(AgentSessionState.WORKING))))
    }

    @Test
    fun waitingForApprovalUpdatesTheSameChat() {
        progress.plan(inputs(chat(AgentSessionState.WORKING)))
        assertEquals(
            listOf(shown(ProgressStage.AWAITING_APPROVAL)),
            progress.plan(inputs(chat(AgentSessionState.AWAITING_APPROVAL))),
        )
    }

    @Test
    fun aRenamedChatIsShownAgain() {
        progress.plan(inputs(chat(AgentSessionState.WORKING)))
        assertEquals(
            listOf(shown(ProgressStage.WORKING, "Renamed")),
            progress.plan(inputs(chat(AgentSessionState.WORKING, title = "Renamed"))),
        )
    }

    @Test
    fun theTurnEndingEndsTheNotification() {
        progress.plan(inputs(chat(AgentSessionState.WORKING)))
        assertEquals(listOf(ProgressAction.End("c1")), progress.plan(inputs(chat(AgentSessionState.IDLE))))
    }

    @Test
    fun comingBackOnScreenEndsIt() {
        progress.plan(inputs(chat(AgentSessionState.WORKING)))
        assertEquals(listOf(ProgressAction.End("c1")), progress.plan(inputs(chat(AgentSessionState.WORKING), away = false)))
    }

    @Test
    fun theSettingOffOrNoSessionShowsNothing() {
        assertEquals(emptyList<ProgressAction>(), progress.plan(inputs(chat(AgentSessionState.WORKING), enabled = false)))
        assertEquals(emptyList<ProgressAction>(), progress.plan(null))
    }

    @Test
    fun aChatReplayingHistoryShowsNothing() {
        assertEquals(emptyList<ProgressAction>(), progress.plan(inputs(chat(AgentSessionState.WORKING, loaded = false))))
    }
}
