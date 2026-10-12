package pl.dmq.peering.feature.agents

import pl.dmq.peering.wire.AgentToolCall

enum class ToolInputKind {
    COMMAND,
    FILE_CHANGE,
    FILE_READ,
    WEB,
    OTHER,
}

/** What an ask would let the agent do, in terms the user can weigh before answering. */
enum class ApprovalRisk {
    RUNS_COMMAND,
    CHANGES_FILES,
    READS_FILES,
    FETCHES_WEB,
    USES_TOOL,
}

/** The one value of a tool call that matters to an approval: the command, the file, or the address. */
data class ToolInputSummary(val kind: ToolInputKind, val primary: String) {
    val risk: ApprovalRisk
        get() = when (kind) {
            ToolInputKind.COMMAND -> ApprovalRisk.RUNS_COMMAND
            ToolInputKind.FILE_CHANGE -> ApprovalRisk.CHANGES_FILES
            ToolInputKind.FILE_READ -> ApprovalRisk.READS_FILES
            ToolInputKind.WEB -> ApprovalRisk.FETCHES_WEB
            ToolInputKind.OTHER -> ApprovalRisk.USES_TOOL
        }

    companion object {
        private val commandNames = setOf("bash", "shell", "run", "exec", "command", "terminal")
        private val changeNames = setOf("edit", "multiedit", "write", "create", "notebookedit", "applypatch", "patch")
        private val readNames = setOf("read", "view", "cat", "open")
        private val webNames = setOf("webfetch", "websearch", "fetch", "search")

        fun of(call: AgentToolCall): ToolInputSummary {
            val name = call.name.trim().lowercase()
            val detail = call.detail?.takeIf { it.isNotBlank() }
            return when {
                name in commandNames -> ToolInputSummary(ToolInputKind.COMMAND, detail ?: call.title)
                name in changeNames -> ToolInputSummary(ToolInputKind.FILE_CHANGE, call.filePath ?: detail ?: call.title)
                name in readNames -> ToolInputSummary(ToolInputKind.FILE_READ, call.filePath ?: detail ?: call.title)
                name in webNames -> ToolInputSummary(ToolInputKind.WEB, detail ?: call.title)
                else -> ToolInputSummary(ToolInputKind.OTHER, detail ?: call.title)
            }
        }
    }
}
