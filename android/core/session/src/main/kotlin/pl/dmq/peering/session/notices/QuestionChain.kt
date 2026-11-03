package pl.dmq.peering.session.notices

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import pl.dmq.peering.session.agent.ApprovalAnswer
import pl.dmq.peering.wire.AgentQuestion

/**
 * An ask of several questions answered from a notification one at a time: each answer posts the next question, and
 * the last one sends every answer together, as the app's own sheet does. [step] is the question being asked and
 * [chosen] the answers to the ones before it.
 */
@Serializable
data class QuestionChain(val steps: List<Step>, val step: Int = 0, val chosen: List<String> = emptyList()) {
    @Serializable
    data class Step(val question: String, val answers: List<String>)

    val current: Step get() = steps[step]

    /** Which question of how many, then the question itself. */
    val body: String get() = ApprovalNotice.truncated("(${step + 1}/${steps.size}) ${current.question}")

    sealed interface Outcome {
        data class Answer(val answer: ApprovalAnswer) : Outcome

        data class Next(val chain: QuestionChain) : Outcome
    }

    /** Null for a button that is not one of this question's answers. */
    fun after(actionID: String): Outcome? {
        val picked = ApprovalNotice.answerFor(actionID, current.answers) as? ApprovalAnswer.Choose ?: return null
        val soFar = chosen + picked.answers
        if (step + 1 >= steps.size) return Outcome.Answer(ApprovalAnswer.Choose(soFar))
        return Outcome.Next(copy(step = step + 1, chosen = soFar))
    }

    fun encoded(): String = json.encodeToString(serializer(), this)

    companion object {
        const val MAX_QUESTIONS = 4
        private val json = Json { ignoreUnknownKeys = true }

        /** Null unless there are several questions and every one fits a notification's buttons. */
        fun of(questions: List<AgentQuestion>): QuestionChain? {
            if (questions.size !in 2..MAX_QUESTIONS) return null
            val steps = questions.map { question ->
                val labels = question.options.map { it.label }.filter { it.isNotEmpty() }
                if (labels.size !in 1..ApprovalNotice.MAX_OPTION_ACTIONS) return null
                Step(question.question, labels)
            }
            return QuestionChain(steps)
        }

        fun decoded(text: String?): QuestionChain? = text?.let {
            runCatching { json.decodeFromString(serializer(), it) }.getOrNull()?.takeIf { chain -> chain.step in chain.steps.indices }
        }
    }
}
