package pl.dmq.peering.session.notices

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.agent.PendingApproval
import pl.dmq.peering.wire.AgentSessionState
import pl.dmq.peering.wire.AgentQuestion
import pl.dmq.peering.wire.AgentToolCall
import pl.dmq.peering.wire.AgentToolOption
import pl.dmq.peering.wire.TerminalAttentionKind

class BackgroundNoticesTest {
    private val notices = BackgroundNotices()

    private fun approval(id: String) = PendingApproval(id, AgentToolCall("t$id", "Bash", "Run", detail = "make"), null)

    private fun chat(
        id: String = "c1",
        state: AgentSessionState = AgentSessionState.WORKING,
        loaded: Boolean = true,
        pending: List<PendingApproval> = emptyList(),
        reply: String? = null,
    ) = ChatView(id, "Chat $id", state, loaded, pending, reply)

    private fun inputs(
        away: Boolean = true,
        enabled: Boolean = true,
        chats: List<ChatView> = emptyList(),
        terminals: List<TerminalView> = emptyList(),
    ) = NoticeInputs(away, enabled, "Studio Mac", "host1", chats, terminals)

    private fun List<NoticeAction>.posted() = filterIsInstance<NoticeAction.Post>().map { it.notice.key }

    private fun List<NoticeAction>.retracted() = filterIsInstance<NoticeAction.Retract>().flatMap { it.keys }

    @Test
    fun aPendingApprovalIsPostedOnceWhileAway() {
        val ask = inputs(chats = listOf(chat(state = AgentSessionState.AWAITING_APPROVAL, pending = listOf(approval("a1")))))
        val first = notices.plan(ask)
        assertEquals(listOf("approval:a1"), first.posted())
        val post = (first.single() as NoticeAction.Post).notice
        assertEquals(NoticeKind.ApprovalNeeded, post.kind)
        assertEquals("Chat c1", post.subject)
        assertEquals("Studio Mac", post.hostName)
        assertEquals(emptyList<NoticeAction>(), notices.plan(ask))
    }

    @Test
    fun nothingIsPostedWhileTheAppIsOnScreen() {
        val ask = inputs(away = false, chats = listOf(chat(pending = listOf(approval("a1")))))
        assertEquals(emptyList<NoticeAction>(), notices.plan(ask))
    }

    @Test
    fun nothingIsPostedWhenTheSettingIsOff() {
        val ask = inputs(enabled = false, chats = listOf(chat(pending = listOf(approval("a1")))))
        assertEquals(emptyList<NoticeAction>(), notices.plan(ask))
    }

    @Test
    fun anApprovalAnsweredElsewhereIsRetracted() {
        notices.plan(inputs(chats = listOf(chat(pending = listOf(approval("a1"), approval("a2"))))))
        val actions = notices.plan(inputs(chats = listOf(chat(pending = listOf(approval("a2"))))))
        assertEquals(setOf("approval:a1"), actions.retracted().toSet())
        assertTrue(actions.posted().isEmpty())
    }

    @Test
    fun returningToTheAppRetractsEverythingAndLeavingAgainAnnouncesWhatStillWaits() {
        val waiting = chat(pending = listOf(approval("a1")))
        notices.plan(inputs(chats = listOf(waiting)))

        val back = notices.plan(inputs(away = false, chats = listOf(waiting)))
        assertEquals(setOf("approval:a1"), back.retracted().toSet())

        assertEquals(listOf("approval:a1"), notices.plan(inputs(chats = listOf(waiting))).posted())
    }

    @Test
    fun anEndedSessionRetractsEverything() {
        notices.plan(inputs(terminals = listOf(TerminalView("t1", "prod", TerminalAttentionKind.PASSWORD))))
        assertEquals(setOf("terminal:t1"), notices.plan(null).retracted().toSet())
        assertEquals(emptyList<NoticeAction>(), notices.plan(null))
    }

    @Test
    fun aChatThatHasNotReplayedItsHistoryAnnouncesNothingAndKeepsItsNotices() {
        assertEquals(emptyList<NoticeAction>(), notices.plan(inputs(chats = listOf(chat(loaded = false, pending = listOf(approval("a1")))))))

        notices.plan(inputs(chats = listOf(chat(pending = listOf(approval("a1"))))))
        val reloading = notices.plan(inputs(chats = listOf(chat(loaded = false))))
        assertEquals(emptyList<NoticeAction>(), reloading)
    }

    @Test
    fun aQuestionIsToldApartFromAToolAsk() {
        val question = PendingApproval(
            "q1",
            AgentToolCall("t", "AskUserQuestion", "Ask", questions = listOf(AgentQuestion(null, "Which?", listOf(AgentToolOption("Yes"))))),
            null,
        )
        val post = notices.plan(inputs(chats = listOf(chat(pending = listOf(question))))).filterIsInstance<NoticeAction.Post>().single().notice
        assertEquals(NoticeKind.QuestionAsked, post.kind)
    }

    @Test
    fun aTurnThatEndsWhileAwayIsAnnouncedWithItsReply() {
        notices.plan(inputs(chats = listOf(chat(state = AgentSessionState.WORKING))))
        val actions = notices.plan(inputs(chats = listOf(chat(state = AgentSessionState.IDLE, reply = "All done."))))
        val post = (actions.single() as NoticeAction.Post).notice
        assertEquals("finished:c1", post.key)
        assertEquals(NoticeKind.AgentFinished, post.kind)
        assertEquals("All done.", post.detail)
    }

    @Test
    fun aFinishedNoticeGoesWhenTheChatWorksAgain() {
        notices.plan(inputs(chats = listOf(chat(state = AgentSessionState.WORKING))))
        notices.plan(inputs(chats = listOf(chat(state = AgentSessionState.IDLE))))
        val again = notices.plan(inputs(chats = listOf(chat(state = AgentSessionState.WORKING))))
        assertEquals(setOf("finished:c1"), again.retracted().toSet())
    }

    @Test
    fun aTurnThatEndedBeforeTheChatWasLoadedIsNotNews() {
        notices.plan(inputs(chats = listOf(chat(state = AgentSessionState.WORKING, loaded = false))))
        val actions = notices.plan(inputs(chats = listOf(chat(state = AgentSessionState.IDLE, loaded = true))))
        assertEquals(emptyList<NoticeAction>(), actions)
    }

    @Test
    fun aTurnThatEndedWhileTheAppWasOnScreenIsNotAnnouncedAfterLeaving() {
        notices.plan(inputs(away = false, chats = listOf(chat(state = AgentSessionState.WORKING))))
        notices.plan(inputs(away = false, chats = listOf(chat(state = AgentSessionState.IDLE))))
        assertEquals(emptyList<NoticeAction>(), notices.plan(inputs(chats = listOf(chat(state = AgentSessionState.IDLE)))))
    }

    @Test
    fun aTerminalWaitingOnAPasswordOrConfirmationIsPostedAndRetractedWhenAnswered() {
        val password = TerminalView("t1", "prod", TerminalAttentionKind.PASSWORD)
        val confirm = TerminalView("t2", "build", TerminalAttentionKind.CONFIRMATION)
        val first = notices.plan(inputs(terminals = listOf(password, confirm)))
        val kinds = first.filterIsInstance<NoticeAction.Post>().map { it.notice.kind }
        assertEquals(listOf(NoticeKind.TerminalPassword, NoticeKind.TerminalConfirmation), kinds)

        val answered = notices.plan(inputs(terminals = listOf(password.copy(attention = null), confirm)))
        assertEquals(setOf("terminal:t1"), answered.retracted().toSet())
    }

    @Test
    fun aTerminalAlreadyWaitingWhenTheAppIsLeftIsAnnounced() {
        val waiting = TerminalView("t1", "prod", TerminalAttentionKind.PASSWORD)
        assertEquals(emptyList<NoticeAction>(), notices.plan(inputs(away = false, terminals = listOf(waiting))))
        assertEquals(listOf("terminal:t1"), notices.plan(inputs(terminals = listOf(waiting))).posted())
    }

    @Test
    fun channelsFollowTheKind() {
        assertEquals(NoticeChannel.Approvals, NoticeKind.QuestionAsked.channel)
        assertEquals(NoticeChannel.Terminals, NoticeKind.TerminalPassword.channel)
        assertEquals(NoticeChannel.Agents, NoticeKind.AgentFinished.channel)
    }
}
