package pl.dmq.peering.feature.agents

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.agent.ApprovalAnswer
import pl.dmq.peering.session.agent.PendingApproval
import pl.dmq.peering.wire.AgentQuestion
import pl.dmq.peering.wire.AgentToolCall
import pl.dmq.peering.wire.AgentToolOption

class ApprovalPresenterTest {
    private val bash = AgentToolCall(id = "c1", name = "Bash", title = "Run command", detail = "rm -rf build")
    private val plan = AgentToolCall(
        id = "c2",
        name = "AskUserQuestion",
        title = "Ask",
        questions = listOf(
            AgentQuestion(header = "Scope", question = "Which files?", options = listOf(AgentToolOption("Tests"), AgentToolOption("Sources"))),
            AgentQuestion(question = "Format?", options = listOf(AgentToolOption("Short"), AgentToolOption("Long"))),
        ),
    )

    private fun presenter(port: FakeAgentsPort, approval: PendingApproval) = ApprovalPresenter(
        port = port,
        sessionID = "S1",
        approval = approval,
        scope = CoroutineScope(UnconfinedTestDispatcher()),
    )

    @Test
    fun aCommandAskShowsItsCommandRiskAndAllowOrDeny() = runTest {
        val ui = presenter(FakeAgentsPort(), PendingApproval("A1", bash, reason = "Deletes build output")).ui.value
        assertEquals("rm -rf build", ui.body)
        assertEquals(ApprovalRisk.RUNS_COMMAND, ui.risk)
        assertEquals(ApprovalSubtitle.WANTS_TO_RUN, ui.subtitle)
        assertTrue(ui.showsAllowAndDeny)
        assertEquals("Deletes build output", ui.reason)
    }

    @Test
    fun reasonIsLeftOutWhenItRepeatsTheCommand() = runTest {
        val ui = presenter(FakeAgentsPort(), PendingApproval("A1", bash, reason = "rm -rf build")).ui.value
        assertNull(ui.reason)
    }

    @Test
    fun allowSendsAllowOnce() = runTest {
        val port = FakeAgentsPort()
        val presenter = presenter(port, PendingApproval("A1", bash, reason = null))
        presenter.allow()
        presenter.deny()
        assertEquals(listOf("approve:S1:A1:Allow"), port.calls)
        assertFalse(presenter.ui.value.enabled)
    }

    @Test
    fun denySendsDeny() = runTest {
        val port = FakeAgentsPort()
        presenter(port, PendingApproval("A1", bash, reason = null)).deny()
        assertEquals(listOf("approve:S1:A1:Deny"), port.calls)
    }

    @Test
    fun aQuestionIsAnsweredOneStepAtATimeAndSentWithEveryLabel() = runTest {
        val port = FakeAgentsPort()
        val presenter = presenter(port, PendingApproval("A2", plan, reason = null))
        assertEquals("Which files?", presenter.ui.value.body)
        assertEquals(ApprovalSubtitle.QUESTION_STEP, presenter.ui.value.subtitle)
        assertNull(presenter.ui.value.risk)
        assertFalse(presenter.ui.value.showsAllowAndDeny)

        presenter.choose("Tests")
        assertTrue(port.calls.isEmpty())
        assertEquals("Format?", presenter.ui.value.body)
        assertEquals(2, presenter.ui.value.stepNumber)
        assertTrue(presenter.ui.value.canGoBack)

        presenter.choose("Long")
        assertEquals(listOf("approve:S1:A2:Choose(answers=[Tests, Long])"), port.calls)
    }

    @Test
    fun backReturnsToTheEarlierQuestionAndDropsItsPick() = runTest {
        val port = FakeAgentsPort()
        val presenter = presenter(port, PendingApproval("A2", plan, reason = null))
        presenter.choose("Sources")
        presenter.back()
        assertEquals("Which files?", presenter.ui.value.body)
        assertFalse(presenter.ui.value.canGoBack)
        presenter.choose("Tests")
        presenter.choose("Short")
        assertEquals(listOf("approve:S1:A2:Choose(answers=[Tests, Short])"), port.calls)
    }

    @Test
    fun labelsPickedAfterTheAnswerWasSentAreIgnored() = runTest {
        val port = FakeAgentsPort()
        val presenter = presenter(port, PendingApproval("A2", plan, reason = null))
        presenter.choose("Tests")
        presenter.choose("Long")
        presenter.choose("Short")
        assertEquals(1, port.calls.size)
    }

    @Test
    fun chooseIsIgnoredForACommandAsk() = runTest {
        val port = FakeAgentsPort()
        presenter(port, PendingApproval("A1", bash, reason = null)).choose("Tests")
        assertTrue(port.calls.isEmpty())
    }
}
