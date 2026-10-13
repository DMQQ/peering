package pl.dmq.peering.session.agent

/** What to do next after a turn that changed the project. */
enum class FollowUp { REVIEW_CHANGES, RUN_TESTS, SUMMARIZE_CHANGES }

object AgentFollowUps {
    private val editingTools = setOf("Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch", "file_change")

    /**
     * Nothing while the agent is busy or waiting, or when the last turn did not change the project: a chat that only
     * answered a question has no next step to guess at.
     */
    fun suggestions(rows: List<TranscriptRow>, working: Boolean): List<FollowUp> {
        if (working || rows.lastOrNull() !is TranscriptRow.TurnSummary) return emptyList()
        val tools = rows.asReversed().takeWhile { it !is TranscriptRow.User }.filterIsInstance<TranscriptRow.ToolCall>()
        val edited = tools.any { it.status == ToolStatus.Ok && (it.call.name in editingTools || !it.call.diff.isNullOrEmpty()) }
        if (!edited) return emptyList()
        val ranTests = tools.any { it.call.detail?.contains("test", ignoreCase = true) == true }
        return listOf(FollowUp.REVIEW_CHANGES) + (if (ranTests) emptyList() else listOf(FollowUp.RUN_TESTS)) + FollowUp.SUMMARIZE_CHANGES
    }

    const val RUN_TESTS_PROMPT = "Run the project's tests and fix anything that fails."
    const val SUMMARIZE_PROMPT = "Summarize what you changed and why, file by file."
}
