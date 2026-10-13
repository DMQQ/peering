package pl.dmq.peering.feature.agents

import pl.dmq.peering.wire.AgentToolOption

enum class ApprovalSubtitle {
    WANTS_TO_RUN,
    ASKS_QUESTION,
    QUESTION_STEP,
}

/** What the approval card shows. [risk] is null for a question, which asks for a choice rather than permission. */
data class ApprovalUi(
    val title: String,
    val subtitle: ApprovalSubtitle,
    val stepNumber: Int,
    val stepCount: Int,
    val body: String,
    val reason: String?,
    val risk: ApprovalRisk?,
    val options: List<AgentToolOption>,
    val showsAllowAndDeny: Boolean,
    val canGoBack: Boolean,
    val enabled: Boolean,
)

/** The user's progress through one ask: the labels picked so far, and whether an answer has been sent. */
internal data class ApprovalProgress(
    val picked: List<String> = emptyList(),
    val answered: Boolean = false,
)
