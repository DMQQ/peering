package pl.dmq.peering.session.notices

import pl.dmq.peering.session.agent.ApprovalAnswer
import pl.dmq.peering.session.agent.PendingApproval
import pl.dmq.peering.wire.AgentToolCall

/** What a notification for an agent's approval request offers, worked out without Android so it can be tested. */
data class ApprovalNotice(
    val approvalID: String,
    val chatID: String,
    val layout: Layout,
    /** The command or reason asked about, cut to what a lock screen shows; empty when the request named neither. */
    val body: String,
    val isQuestion: Boolean,
) {
    sealed interface Layout {
        /** A tool wants to run: allow or deny. */
        data object AllowDeny : Layout

        /** One question with a few answers, each its own button. */
        data class Options(val labels: List<String>) : Layout

        /** Several questions, a plan, or a command too long to judge from a banner: only the app can answer. */
        data object OpenOnly : Layout
    }

    data class Action(val id: String, val title: Title, val requiresAuthentication: Boolean)

    sealed interface Title {
        data object Allow : Title

        data object Deny : Title

        data class Label(val text: String) : Title
    }

    val actions: List<Action> get() = actionsFor(layout)

    /** The full labels of a question's options, which the action ids index into. */
    val answers: List<String> get() = (layout as? Layout.Options)?.labels.orEmpty()

    companion object {
        /** A notification shows about three buttons before the system folds them. */
        const val MAX_OPTION_ACTIONS = 3
        const val MAX_OPTION_TITLE = 40
        const val MAX_BODY = 240

        const val ALLOW = "allow"
        const val DENY = "deny"
        private const val OPTION_PREFIX = "choose."

        fun of(chatID: String, approval: PendingApproval): ApprovalNotice {
            val call = approval.call
            return ApprovalNotice(
                approvalID = approval.approvalID,
                chatID = chatID,
                layout = layoutFor(call),
                body = truncated(bodyText(call.detail, approval.reason)),
                isQuestion = !call.questions.isNullOrEmpty(),
            )
        }

        internal fun layoutFor(call: AgentToolCall): Layout {
            val questions = call.questions.orEmpty()
            if (call.name == "ExitPlanMode" || questions.size > 1) return Layout.OpenOnly
            if (questions.isEmpty()) return if (showsWholeCommand(call)) Layout.AllowDeny else Layout.OpenOnly
            val labels = questions[0].options.map { it.label }.filter { it.isNotEmpty() }
            return if (labels.size in 1..MAX_OPTION_ACTIONS) Layout.Options(labels) else Layout.OpenOnly
        }

        /** One tap must not approve what the banner cut short or never named: the app shows the whole request. */
        private fun showsWholeCommand(call: AgentToolCall): Boolean {
            val command = call.detail?.trim().orEmpty()
            return command.isNotEmpty() && command.length < MAX_BODY
        }

        /** The command is what the user decides on; the CLI's reason only ever follows it. */
        internal fun bodyText(command: String?, reason: String?): String =
            listOfNotNull(command, reason).map { it.trim() }.filter { it.isNotEmpty() }.joinToString("\n\n")

        internal fun actionsFor(layout: Layout): List<Action> = when (layout) {
            Layout.AllowDeny -> listOf(
                Action(DENY, Title.Deny, requiresAuthentication = false),
                Action(ALLOW, Title.Allow, requiresAuthentication = true),
            )
            is Layout.Options -> layout.labels.mapIndexed { index, label ->
                Action(OPTION_PREFIX + index, Title.Label(truncated(label, MAX_OPTION_TITLE)), requiresAuthentication = false)
            }
            Layout.OpenOnly -> emptyList()
        }

        /** The answer a tapped button stands for, or null for an id that is not one. [answers] are the full labels. */
        fun answerFor(actionID: String, answers: List<String>): ApprovalAnswer? = when {
            actionID == ALLOW -> ApprovalAnswer.Allow
            actionID == DENY -> ApprovalAnswer.Deny
            actionID.startsWith(OPTION_PREFIX) ->
                actionID.removePrefix(OPTION_PREFIX).toIntOrNull()?.let(answers::getOrNull)?.let { ApprovalAnswer.Choose(listOf(it)) }
            else -> null
        }

        internal fun truncated(text: String, limit: Int = MAX_BODY): String {
            val trimmed = text.trim()
            if (trimmed.length <= limit) return trimmed
            return trimmed.take(maxOf(limit - 1, 0)).trim() + "…"
        }
    }
}
