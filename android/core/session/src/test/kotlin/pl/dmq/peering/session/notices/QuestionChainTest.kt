package pl.dmq.peering.session.notices

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.session.agent.ApprovalAnswer
import pl.dmq.peering.session.agent.PendingApproval
import pl.dmq.peering.wire.AgentQuestion
import pl.dmq.peering.wire.AgentToolCall
import pl.dmq.peering.wire.AgentToolOption

class QuestionChainTest {
    private fun ask(vararg questions: List<String>) = PendingApproval(
        "a1",
        AgentToolCall(
            "t1", "AskUserQuestion", "Ask",
            questions = questions.mapIndexed { index, labels -> AgentQuestion(null, "Q${index + 1}?", labels.map { AgentToolOption(it) }) },
        ),
        null,
    )

    @Test
    fun severalQuestionsStartOnTheFirstOnesAnswers() {
        val notice = ApprovalNotice.of("c1", ask(listOf("Red", "Blue"), listOf("Big", "Small")))
        assertEquals(ApprovalNotice.Layout.Options(listOf("Red", "Blue")), notice.layout)
        assertEquals("(1/2) Q1?", notice.body)
    }

    @Test
    fun eachAnswerBeforeTheLastAsksTheNextAndTheLastSendsThemAll() {
        val first = ApprovalNotice.of("c1", ask(listOf("Red", "Blue"), listOf("Big", "Small"), listOf("Yes", "No"))).chain!!
        val second = (first.after("choose.1") as QuestionChain.Outcome.Next).chain
        assertEquals("(2/3) Q2?", second.body)
        val third = (second.after("choose.0") as QuestionChain.Outcome.Next).chain
        assertEquals(QuestionChain.Outcome.Answer(ApprovalAnswer.Choose(listOf("Blue", "Big", "No"))), third.after("choose.1"))
    }

    @Test
    fun aChainSurvivesTheIntentItRidesIn() {
        val chain = (ApprovalNotice.of("c1", ask(listOf("Red"), listOf("Big"))).chain!!.after("choose.0") as QuestionChain.Outcome.Next).chain
        assertEquals(chain, QuestionChain.decoded(chain.encoded()))
        assertNull(QuestionChain.decoded("not json"))
    }

    @Test
    fun aButtonThatIsNotAnAnswerDoesNothing() {
        val chain = ApprovalNotice.of("c1", ask(listOf("Red"), listOf("Big"))).chain!!
        assertNull(chain.after("allow"))
        assertNull(chain.after("choose.5"))
    }

    @Test
    fun aQuestionWithTooManyAnswersMakesNoChain() {
        assertNull(ApprovalNotice.of("c1", ask(listOf("a", "b", "c", "d"), listOf("x"))).chain)
    }
}
