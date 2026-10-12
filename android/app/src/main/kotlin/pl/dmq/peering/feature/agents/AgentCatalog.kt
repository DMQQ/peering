package pl.dmq.peering.feature.agents

/** An agent the Mac can start a chat with. [name] falls back to the id for an agent this build does not know. */
data class AgentOption(val id: String, val name: String)

object AgentCatalog {
    private val names = mapOf(
        "claude" to "Claude Code",
        "codex" to "Codex",
        "opencode" to "OpenCode",
    )

    /** The agents the Mac declared in its handshake, in the order it declared them. */
    fun options(declaredIDs: List<String>): List<AgentOption> =
        declaredIDs.distinct().map { AgentOption(it, names[it] ?: it) }
}
