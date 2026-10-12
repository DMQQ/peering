package pl.dmq.peering.feature.agents

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import pl.dmq.peering.session.agent.ApprovalAnswer
import pl.dmq.peering.session.agent.PendingApproval

/**
 * One open ask. A question-style ask is answered one question at a time, and the answer is sent once every question
 * has a label. Only one answer is sent: after it, the buttons stay disabled until the Mac drops the ask.
 */
class ApprovalPresenter(
    private val port: AgentsPort,
    private val sessionID: String,
    private val approval: PendingApproval,
    scope: CoroutineScope,
) {
    private val progress = MutableStateFlow(ApprovalProgress())

    val ui: StateFlow<ApprovalUi> = progress
        .map { derive(it) }
        .stateIn(scope, SharingStarted.Eagerly, derive(ApprovalProgress()))

    fun allow() = answer(ApprovalAnswer.Allow)

    fun deny() = answer(ApprovalAnswer.Deny)

    fun choose(label: String) {
        val current = progress.value
        if (current.answered) return
        val questions = approval.call.questions.orEmpty()
        if (questions.isEmpty() || current.picked.size >= questions.size) return
        val picked = current.picked + label
        if (picked.size == questions.size) {
            answer(ApprovalAnswer.Choose(picked))
        } else {
            progress.update { it.copy(picked = picked) }
        }
    }

    fun back() {
        progress.update { if (it.answered || it.picked.isEmpty()) it else it.copy(picked = it.picked.dropLast(1)) }
    }

    private fun answer(answer: ApprovalAnswer) {
        val current = progress.value
        if (current.answered) return
        progress.update { it.copy(answered = true) }
        port.approve(sessionID, approval.approvalID, answer)
    }

    private fun derive(state: ApprovalProgress): ApprovalUi {
        val call = approval.call
        val questions = call.questions.orEmpty()
        val step = questions.getOrNull(state.picked.size)
        val summary = ToolInputSummary.of(call)
        val options = step?.options.orEmpty()
        val subtitle = when {
            questions.isEmpty() -> ApprovalSubtitle.WANTS_TO_RUN
            questions.size > 1 -> ApprovalSubtitle.QUESTION_STEP
            else -> ApprovalSubtitle.ASKS_QUESTION
        }
        return ApprovalUi(
            title = step?.header ?: call.title,
            subtitle = subtitle,
            stepNumber = state.picked.size + 1,
            stepCount = questions.size,
            body = step?.question ?: summary.primary,
            reason = approval.reason?.takeIf { step == null && it.isNotBlank() && it != summary.primary },
            risk = if (questions.isEmpty()) summary.risk else null,
            options = options,
            showsAllowAndDeny = options.isEmpty(),
            canGoBack = state.picked.isNotEmpty(),
            enabled = !state.answered,
        )
    }
}
