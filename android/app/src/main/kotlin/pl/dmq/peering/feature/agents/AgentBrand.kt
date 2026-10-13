package pl.dmq.peering.feature.agents

/** Which known agent an id names, so the UI can give it its own glyph and one line of description. */
enum class AgentBrand {
    CLAUDE,
    CODEX,
    OPENCODE,
    OTHER,
    ;

    companion object {
        fun of(agentID: String): AgentBrand = when (agentID) {
            "claude" -> CLAUDE
            "codex" -> CODEX
            "opencode" -> OPENCODE
            else -> OTHER
        }
    }
}
