package pl.dmq.peering.session.notices

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.agent.ApprovalAnswer
import pl.dmq.peering.session.agent.PendingApproval
import pl.dmq.peering.wire.AgentQuestion
import pl.dmq.peering.wire.AgentToolCall
import pl.dmq.peering.wire.AgentToolOption

class ApprovalNoticeTest {
    private fun ask(
        name: String = "Bash",
        detail: String? = "ls -la",
        reason: String? = null,
        questions: List<AgentQuestion>? = null,
    ) = PendingApproval("a1", AgentToolCall("t1", name, "Run", detail = detail, questions = questions), reason)

    private fun question(vararg labels: String) = AgentQuestion(null, "Which?", labels.map { AgentToolOption(it) })

    @Test
    fun aShortCommandOffersAllowAndDeny() {
        val notice = ApprovalNotice.of("c1", ask())
        assertEquals(ApprovalNotice.Layout.AllowDeny, notice.layout)
        assertEquals(listOf("deny", "allow"), notice.actions.map { it.id })
        assertEquals(listOf(false, true), notice.actions.map { it.requiresAuthentication })
    }

    @Test
    fun aCommandTooLongForABannerIsOnlyOpened() {
        val notice = ApprovalNotice.of("c1", ask(detail = "x".repeat(ApprovalNotice.MAX_BODY)))
        assertEquals(ApprovalNotice.Layout.OpenOnly, notice.layout)
        assertTrue(notice.actions.isEmpty())
    }

    @Test
    fun anAskThatNamesNoCommandIsOnlyOpened() {
        assertEquals(ApprovalNotice.Layout.OpenOnly, ApprovalNotice.of("c1", ask(detail = "  ")).layout)
        assertEquals(ApprovalNotice.Layout.OpenOnly, ApprovalNotice.of("c1", ask(detail = null)).layout)
    }

    @Test
    fun aPlanAndSeveralQuestionsAreOnlyOpened() {
        assertEquals(ApprovalNotice.Layout.OpenOnly, ApprovalNotice.of("c1", ask(name = "ExitPlanMode")).layout)
        val two = ask(detail = null, questions = listOf(question("a"), question("b")))
        assertEquals(ApprovalNotice.Layout.OpenOnly, ApprovalNotice.of("c1", two).layout)
    }

    @Test
    fun oneQuestionGetsAButtonPerAnswerUpToThree() {
        val notice = ApprovalNotice.of("c1", ask(detail = null, questions = listOf(question("Yes", "No"))))
        assertTrue(notice.isQuestion)
        assertEquals(listOf("choose.0", "choose.1"), notice.actions.map { it.id })
        assertEquals(listOf("Yes", "No"), notice.answers)
        val tooMany = ask(detail = null, questions = listOf(question("a", "b", "c", "d")))
        assertEquals(ApprovalNotice.Layout.OpenOnly, ApprovalNotice.of("c1", tooMany).layout)
    }

    @Test
    fun aLongAnswerLabelIsShortenedOnItsButtonButAnsweredInFull() {
        val label = "y".repeat(80)
        val notice = ApprovalNotice.of("c1", ask(detail = null, questions = listOf(question(label))))
        val title = (notice.actions.single().title as ApprovalNotice.Title.Label).text
        assertEquals(ApprovalNotice.MAX_OPTION_TITLE, title.length)
        assertEquals(ApprovalAnswer.Choose(listOf(label)), ApprovalNotice.answerFor("choose.0", notice.answers))
    }

    @Test
    fun theBodyPutsTheCommandBeforeTheReasonAndIsCut() {
        assertEquals("ls -la\n\nlists files", ApprovalNotice.of("c1", ask(reason = "lists files")).body)
        val body = ApprovalNotice.of("c1", ask(detail = "z".repeat(500))).body
        assertEquals(ApprovalNotice.MAX_BODY, body.length)
        assertTrue(body.endsWith("…"))
    }

    @Test
    fun buttonsMapToAnswersAndUnknownIdsToNothing() {
        assertEquals(ApprovalAnswer.Allow, ApprovalNotice.answerFor("allow", emptyList()))
        assertEquals(ApprovalAnswer.Deny, ApprovalNotice.answerFor("deny", emptyList()))
        assertEquals(ApprovalAnswer.Choose(listOf("B")), ApprovalNotice.answerFor("choose.1", listOf("A", "B")))
        assertNull(ApprovalNotice.answerFor("choose.2", listOf("A", "B")))
        assertNull(ApprovalNotice.answerFor("choose.x", listOf("A")))
        assertNull(ApprovalNotice.answerFor("open", listOf("A")))
    }
}
